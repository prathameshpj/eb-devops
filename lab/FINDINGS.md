# Findings — Part 4 debug lab

Recording: [`part4-session.log`](part4-session.log), made with `script`. Each fix is a separate commit, so `git log -- lab/broken-chart` shows the order I fixed things in.

My setup: kind v0.33.0, Kubernetes v1.37.0, Helm v4.0.5 on an arm64 Mac. The lab image `ebinterview/eb-debug-app:1.0.1` is amd64 only, so on my machine it runs under emulation.

Where I ended up: `./scenario.sh verify` passes 7 to 9 of the 11 checks. I found and fixed seven problems in the chart. The reporter still fails. I found out why (it's inside the image, see defect 8), but I couldn't fix it from the chart. The brief says there are six defects and I changed seven things, so either one of mine doesn't count as a separate defect, or the reporter is the one I didn't solve.

One trap before the defects: on a new cluster the first `./scenario.sh up` can't create the LimitRange (`namespaces "debug-lab" not found`), because `kubectl apply -f cluster-state/` applies `limits.yaml` before `namespace.yaml`. Running `up` a second time fixes it. On my first install this meant the metrics pod was created without the LimitRange, which hid defect 3 for a while. I didn't touch `cluster-state/`.

---

## Defect 1: migrate Job has an invalid restartPolicy

**Symptom:**
```
$ ./scenario.sh up
Error: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
$ helm -n debug-lab history debug-lab
1  ...  failed  ...  Release "debug-lab" failed: Job.batch "migrate" is invalid: ...
```

**Cause:** `templates/migrate-job.yaml` had `restartPolicy: Always`. Jobs only allow `Never` or `OnFailure`, so the API server rejected the Job and Helm marked the whole release as failed. That left the rest of the install half done, which made everything else confusing at the start.

**Fix:** changed it to `restartPolicy: Never`. With `Never`, every retry gets a new pod and the failed ones stay around (up to `backoffLimit: 2`), so I can still read their logs. With `OnFailure` the container restarts inside the same pod and the old logs are lost.

**How I found it:** `scenario.sh up` printed the error, and `helm history` confirmed the release had failed. After the fix the Job completed and its log said `migration complete`.

---

## Defect 2: runAsNonRoot, but the image user is a name and not a number

**Symptom:** every pod was stuck in `CreateContainerConfigError`:
```
$ kubectl -n debug-lab get events --sort-by=.lastTimestamp
Warning Failed pod/backend-...  Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```
Gateway, reporter, metrics and worker showed the same error.

**Cause:** the image sets `USER nonroot`, which is a name. The chart sets `runAsNonRoot: true`, and Kubernetes can only check that against a numeric user ID, so it refuses to start the container. The YAML looks fine; you only see this in the cluster.

**Fix:** I set `runAsUser: 65532` and `runAsGroup: 65532` once in `values.yaml` (`podSecurityContext`) and used it in all six workloads, including the Job. I took 65532 from the image's own `/etc/passwd`. The image has no shell, so I copied the file out with `docker cp`:
```
$ docker cp $id:/etc/passwd - | tar -xO
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```
I didn't just remove `runAsNonRoot`, because that turns off a safety check to hide the error.

**How I found it:** `kubectl get events`, then `describe pod`, then `docker image inspect` to see the image's user, then `/etc/passwd` from the image to get the number.

---

## Defect 3: metrics asks for more CPU than the namespace allows

**Symptom:** the metrics Deployment was `0/1`, its ReplicaSet showed `CURRENT 0`, and there were no pods at all:
```
$ kubectl -n debug-lab describe rs -l app=metrics
Warning FailedCreate ... Error creating: pods "metrics-6ccfc8ffcf-4r4dl" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:** `values.yaml` gave metrics a CPU request of `2` and a limit of `4`. The LimitRange in `cluster-state/limits.yaml` allows at most 1 CPU per container, so every pod was rejected. Because no pod is ever created, `kubectl get pods` shows nothing; the error only shows up on the ReplicaSet.

**Fix:** a request of `50m` and a limit of `200m`, the same as the other services. It runs the same app as backend (`APP_MODE=api`), so there was no reason for 2 to 4 CPUs. Changing the LimitRange isn't allowed, and the chart was the thing that was wrong anyway.

**How I found it:** `get rs` showed the new ReplicaSet with `CURRENT 0`, and `describe rs` showed the event.

---

## Defect 4: the app listens on 8081, but everything points at 8080

**Symptom:** pods were `Running` but `0/1`:
```
$ kubectl -n debug-lab logs deploy/backend
eb-debug-app 2.0.0 starting: mode=api pod=backend-... listening on :8081 (image default is 8081; set PORT to override)
$ kubectl -n debug-lab describe pod -l app=backend
Warning Unhealthy ... Readiness probe failed: Get "http://10.244.0.32:8080/healthz": dial tcp 10.244.0.32:8080: connect: connection refused
```

**Cause:** the chart uses 8080 everywhere (container port, probe, Service). The app listens on 8081 unless `PORT` is set. `docker image inspect` shows the same: `ExposedPorts=map[8081/tcp:{}]`.

**Fix:** I pass `PORT` (from `common.port`) to every Deployment, so one value controls the app's port, the probe and the Service. I could have changed `common.port` to 8081 instead, but then the chart would still depend on a default inside the image that could change.

**How I found it:** `logs` on a pod that was Running but not Ready, then `describe` for the probe error, then `docker image inspect` for the port.

---

## Defect 5: worker needs a writable cache folder

**Symptom:** the worker was in `CrashLoopBackOff`:
```
$ kubectl -n debug-lab logs deploy/worker --previous
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:** the root filesystem is read-only, which is good practice, but the worker needs to write its cache to `/var/cache/app`.

**Fix:** an `emptyDir` volume (limited to 64Mi) mounted at `/var/cache/app`, on the worker only. I kept `readOnlyRootFilesystem` on. Turning it off would also work, but then every other path becomes writable too.

**How I found it:** it was the only pod crash-looping, and `logs --previous` said exactly what was wrong.

---

## Defect 6: gateway points at the backend in the wrong namespace

**Symptom:** the backend was healthy, but the gateway stayed `0/1`:
```
$ kubectl -n debug-lab logs -l app=gateway --prefix
readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: ... dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
GET /healthz -> 503
```
From a busybox pod in the namespace, `wget http://backend:8080/healthz` returned `{"status":"ok"}`, while `wget http://backend.default.svc:8080` returned `bad address`.

**Cause:** `BACKEND_URL` was `http://backend.default.svc:8080`, but the lab runs in `debug-lab`, so that name doesn't exist. The gateway's readiness check calls the backend, so the gateway never became ready. I only saw this after fixing defects 2 and 4, because before that the gateway couldn't even start.

**Fix:** `BACKEND_URL: http://backend:8080`. The short name works in whatever namespace the chart is installed in, and it's also the address `verify` uses.

**How I found it:** the gateway logs, then a throwaway busybox pod to test DNS and HTTP.

---

## Defect 7: the reporter's permission was given to the wrong ServiceAccount

**Symptom:**
```
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no
$ kubectl -n debug-lab get rolebinding reporter-read -o jsonpath='{.subjects}'
[{"kind":"ServiceAccount","name":"default","namespace":"debug-lab"}]
$ kubectl -n debug-lab logs -l app=reporter
pod list failed: kubernetes API returned HTTP 403: ... "pods is forbidden: User \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" ..."
```

**Cause:** the Role is fine (`get` and `list` on pods), but the RoleBinding gave it to the `default` ServiceAccount. The reporter runs as `reporter`.

**Fix:** the binding's subject and the ServiceAccount's name now both come from `reporter.serviceAccountName`, so they can't get out of sync. After the fix, `can-i` says `yes`.

**How I found it:** the 403 in the reporter logs, then `auth can-i`, then comparing the binding's subject with the pod's `serviceAccountName`.

---

## Defect 8 (not fixed): the reporter only reads the first 1024 bytes of the pod list

**Symptom:** after fixing defect 7 the 403 went away, but a new error appeared:
```
pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503
$ curl localhost:18181/report   (via port-forward)
{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
```
In `verify` this shows up as `deployment reporter: 0/1 ready` and `reporter /report does not return a pod count`.

**What I tried** (all of it is in the recording):

| Idea | What I did | Result |
|---|---|---|
| The API sends bad data | `kubectl get --raw …/pods?limit=100 --as=…:reporter` | valid JSON, 7 pods, about 51 KB |
| The network or API is slow | `curl` from a debug container in the reporter pod, using the pod's own token | `http=200 bytes=112414 time=0.0087s` |
| Not enough CPU | raised `limits.cpu` to 1 for a test | same error |
| Too many pods | reporter on its own in a separate namespace | same error |
| Does anything work? | pointed the reporter at an empty namespace | works: `{"pods":0}` |
| Emulation on my Mac | switched from Rosetta to QEMU; also ran a small Go client of my own under the same emulation | reporter: same error. My client read the whole list fine |
| HTTP/2 | `GODEBUG=http2client=0` | same error |
| Kubernetes version | a test cluster on Kubernetes 1.32 | same error |
| Needs a writable folder | `emptyDir` at `/tmp` and `/var/cache/app` | same error |
| A setting I missed | listed every env var name in the binary | only `APP_MODE, APP_NAME, VERSION, PORT, BACKEND_URL, NAMESPACE, CACHE_DIR, MIGRATE_SECONDS` |

My first guess was wrong. The empty-namespace reply had a `content-length` header and the failing replies didn't, so I thought the reporter needed that header. But the empty reply is also tiny, so I had to test size and the header separately.

**How I found the real cause:** I ran the real reporter (same image) against a small fake Kubernetes API that I wrote, running as a second container in the same pod. A `hostAliases` entry pointed `kubernetes.default.svc` at it, with its own test certificate and token. The fake API returns a valid pod list of an exact size, with or without a `Content-Length` header, and logs what the reporter asks for:
```
CASE           BODY       READY     REPORTER SAYS
cl-1000-1      1000       true      eb-debug-app 0.0.0 starting: mode=reporter ...
cl-1024-1      1024       true      eb-debug-app 0.0.0 starting: mode=reporter ...
cl-1025-1      1025       false     pod list failed: parse pod list: unexpected end of JSON inpu
nocl-1024-1    1024       true      eb-debug-app 0.0.0 starting: mode=reporter ...
nocl-1025-1    1025       false     pod list failed: parse pod list: unexpected end of JSON inpu
cl-43499-1     43499      false     pod list failed: parse pod list: unexpected end of JSON inpu

==> what the reporter requested (from the fake API's log):
REQ proto=HTTP/1.1 GET /api/v1/namespaces/cl-1000-1/pods?limit=100 accept="" accept-encoding="gzip" ua="Go-http-client/1.1" auth=true
```
(`cl` = with a Content-Length header, `nocl` = without; the number is the exact size of the reply in bytes.) I left this test code out of the final repo to keep it small. It's in commit `339743f` if you want to run it.

What this shows:
- 1024 bytes works and 1025 fails, with or without the header.
- Changing memory, CPU, `CACHE_DIR`, the other env vars or `GOMEMLIMIT` doesn't move the limit.
- The binary decodes the reply into `struct { Items []json.RawMessage }`. It only counts the items, so a reply that's cut short is the only way to get this error.

**Why the chart can't fix it:** `verify` needs at least one pod, and the reporter's own pod is always in the list. One pod here is about 7 KB (6.9 to 7.6 KB). The smallest one-pod list I could make was 4,684 bytes, and the `debug-lab` list is 43,499 bytes. Only an empty namespace (86 bytes) is under 1024, and that's the only case that ever worked.

The only ways around it would be cheating the check, for example sending the reporter to a fake API or faking the count. I didn't do that; the brief is clear about not making an alert go away without fixing the cause. My conclusion is that the image only reads a fixed 1 KB of the response. That's inside the image, which we're not allowed to change. It also explains why CPU, emulation, HTTP/2 and the Kubernetes version made no difference: none of them changes the size of the reply.

**About the other two failing checks:** `backend does not answer` and `gateway /status does not report backend=ok` come and go between runs (9/11 once, 7/11 later, with nothing changed). The backend and gateway are fine. `verify` runs its checks in a temporary pod with `kubectl run -i`, and kubectl only connects to the pod's output a moment after it starts. The backend and gateway checks finish in milliseconds, so their lines are often printed before kubectl is listening, and they get lost:
```
$ incluster_probe          # exact function from scenario.sh, 4 runs in a row
PROBE_REPORTER_BODY=
PROBE_DNS=fail             # (identical on all 4 runs; first two lines missing)
```
The same script with a `sleep 2;` added at the start (in a copy; `scenario.sh` itself is unchanged):
```
PROBE_BACKEND=ok
PROBE_GATEWAY_BODY={"app":"gateway","backend":"ok","backend_url":"http://backend:8080",...,"self":"ok"}
PROBE_REPORTER_BODY=
PROBE_DNS=fail
```
Running the probe as a normal pod and reading `kubectl logs` shows the same: the backend is ok and the gateway reports `"backend":"ok"`. The reporter line is `Connection refused` because the reporter isn't ready. (`PROBE_DNS=fail` comes from busybox `nslookup`, and `verify` doesn't count it.) I first thought the reporter caused the lost lines. It doesn't: the reporter refuses the connection instantly, and the lines are still lost. So the only real failures are the two reporter checks.

**What I would do next:**
1. Report it to the image owner (here, the hiring team) with the fake API test as proof: "the reporter cuts the pod list at 1024 bytes, so any namespace with pods fails".
2. In a real incident, roll back to the last image version that worked and ask for a fix that reads the whole response.

**Things I learned along the way:**
- A `helm upgrade --set` value from one of my tests stuck around in later upgrades, because Helm reuses the previous values if you don't pass new ones. I saw it with `helm get values`, then cleaned up with `--reset-values` and a fresh `reset` + `up` before the final verify.
- Helm 4 uses server-side apply, so fields added with `kubectl patch` aren't removed by a later `helm upgrade`. That's another reason to finish with a clean reinstall.
