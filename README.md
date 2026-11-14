# DevOps take-home

| Part | Where | Status |
|---|---|---|
| 1. Service + Dockerfile | [`service/`](service/) | done |
| 2. Helm chart | [`chart/`](chart/) | done |
| 3. One-command setup | [`setup.sh`](setup.sh) | done, tested from a fresh cluster and re-run several times |
| 4. Debug lab | [`lab/`](lab/), [`FINDINGS.md`](lab/FINDINGS.md), [`part4-session.log`](lab/part4-session.log) | 7 fixes, `verify` 7–9/11. The reporter still fails because of a problem inside the image (details in FINDINGS) |
| 5. Written answer | [`ANSWERS.md`](ANSWERS.md) | done |
| Bonus: CI | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | lint, build, Trivy scan |

## How to run it

You need Docker (running), `kind`, `kubectl` and `helm`. Ports 80 and 443 must be free. If they aren't, run `HTTP_PORT=8080 HTTPS_PORT=8443 ./setup.sh`.

```bash
./setup.sh
```

It's safe to run more than once. It:
1. creates the kind cluster `demo`, or reuses it if it already exists
2. installs ingress-nginx (`controller-v1.15.1`) from a copy of the manifest saved in [`deploy/`](deploy/)
3. builds the image (the unit tests run during the build) and loads it into kind
4. runs `helm upgrade --install demo ./chart -n demo --create-namespace --wait`
5. calls the service through the Ingress to check it works

All `kubectl` and `helm` commands in the script use `--context kind-demo`, so it can't touch any other cluster in your kubeconfig.

If you're behind a company proxy that inspects HTTPS, kind can't pull images (`x509: certificate signed by unknown authority`). Export the proxy's root certificate to a file and run `EXTRA_CA_CERT=/path/ca.pem ./setup.sh`. I had to do this on my network.

### Check that it works

```bash
kubectl --context kind-demo -n demo get pods,svc,ingress          # 2 pods Running, Ingress for demo.local
curl -s -H 'Host: demo.local' http://localhost/                   # {"app": "demo-service", "version": "0.1.0", "pod": "demo-..."}
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: demo.local' http://localhost/healthz   # 200
for i in 1 2 3 4; do curl -s -H 'Host: demo.local' http://localhost/; echo; done          # "pod" changes between the 2 replicas

# optional, to use the hostname directly:
echo '127.0.0.1 demo.local' | sudo tee -a /etc/hosts && curl -s http://demo.local/
```

**Changing the ConfigMap without a redeploy:**
```bash
kubectl --context kind-demo -n demo patch configmap demo --type merge -p '{"data":{"APP_NAME":"patched"}}'
# wait up to ~60s, no pod restart needed:
curl -s -H 'Host: demo.local' http://localhost/      # {"app": "patched", ...}
```
On my machine this took about 30 seconds, with no restarts. If you change the value with `helm upgrade --set config.appName=...` instead, the pods restart straight away (the chart has a `checksum/config` annotation).

**Chart overrides:**
```bash
helm template demo chart --set replicaCount=3 --set config.appName=foo | grep -E 'replicas:|APP_NAME'
```

**Part 4 lab:**
```bash
cd lab && ./scenario.sh up && ./scenario.sh up && ./scenario.sh verify
```
On a new cluster run `up` twice: the first time, the LimitRange is applied before its namespace exists (explained in FINDINGS).

## How it's built

**Service** ([`service/app.py`](service/app.py)): plain Python, standard library only, so there are no packages to install or keep patched. `APP_NAME` and `VERSION` are read again on every request:
1. If there's a file for the value in `$CONFIG_DIR`, it uses that. The chart mounts the ConfigMap there, and Kubernetes updates mounted files when the ConfigMap changes.
2. Otherwise it uses the environment variable. That's what `docker run -e` sets, and the chart sets it too.

Environment variables can't change inside a running process, so on their own they couldn't pick up a ConfigMap change without a restart. That's why the chart mounts the ConfigMap as files as well.

The app shuts down cleanly when Kubernetes stops it, and the chart adds a 5 second pause before shutdown so the Ingress stops sending traffic first.

**Dockerfile:** two stages, based on `python:3.13.9-alpine3.22`.
- The first stage runs the unit tests. If a test fails, no image is built.
- The second stage only contains `app.py` and runs as user ID `10001`. It's a number on purpose: Kubernetes can only check `runAsNonRoot` against a numeric ID (that's exactly lab defect 2).
- `.dockerignore` only lets the two Python files in. The image is 72.5 MB.

**Chart:**
- Rolling updates with `maxUnavailable: 0` and `maxSurge: 1`, so a new pod is ready before an old one is removed.
- A PodDisruptionBudget (`maxUnavailable: 1`), added only when there's more than one replica.
- Locked-down pods: non-root, read-only filesystem, all Linux capabilities dropped, default seccomp profile, and no ServiceAccount token, since the app never talks to the Kubernetes API.
- The probes use the named port `http`.

### Resource requests and limits

I measured these on kind with `crictl stats`:

| | request | limit | What I measured |
|---|---|---|---|
| CPU | `50m` | `250m` | Almost nothing when idle. Under a load test (50 concurrent requests through the Ingress, about 370 requests/s across 2 pods), each pod hit the 250m limit and got throttled, and one request timed out. |
| memory | `32Mi` | `128Mi` | 11.7 MB idle, 13.3 MB under load |

- **Requests** are what the pod normally needs, so the scheduler doesn't reserve space that's never used. 50m is about twice normal light traffic, and 32Mi is about 2.5 times the memory it actually uses.
- **The memory limit** is a safety net. The server starts a thread per connection, so a flood of connections increases memory use. 128Mi leaves plenty of room, and if something goes wrong the pod gets restarted instead of affecting other pods.
- **The CPU limit** is a trade-off. Throttling started at about 185 requests/s per pod, which is fine here. For real traffic I'd add pods (an HPA at around 70% CPU) rather than make one pod bigger.
- Because requests are lower than limits, the pods are in the "Burstable" QoS class. For something critical I'd set the memory request equal to the limit so it's less likely to be evicted.

## What I skipped, and the risk

| Skipped | Risk |
|---|---|
| TLS on the Ingress | Traffic isn't encrypted. Fine on a local kind cluster, not anywhere else. The chart has an `ingress.tls` value ready for it. |
| Autoscaling (HPA) and spreading pods across nodes | Two fixed replicas can't handle a big traffic spike. On a single kind node, both replicas would also go down together. |
| NetworkPolicy | Any pod in the cluster can call the service. Next step would be deny-by-default and only allow traffic from ingress-nginx. |
| A registry, image signing and pinning by digest | The chart uses the tag `demo-service:0.1.0` and relies on `kind load`. Tags can be overwritten; in production I'd push to a registry, deploy by digest, and sign images. |
| ConfigMap changes take up to ~60s | For a short time the two pods can show different values. Forcing a restart on every change would avoid that, but I didn't want pods restarting for every config edit. |
| `setup.sh` uses `--force-conflicts` on Helm 4 | If someone changes an object by hand, the next `setup.sh` overwrites it without asking. That's intended (git is the source of truth), but worth knowing. |
| Trivy scan only in CI | Trivy couldn't download its database through my network's proxy, so I haven't run it locally. The CI workflow runs it. |

## What I'd change for production

- **Images:** build in CI, push to a registry, deploy by digest, sign them, and keep the Trivy check.
- **Deploying:** use GitOps (Argo CD or Flux) instead of running `helm upgrade` from a laptop, with separate values files per environment.
- **Running:** HPA, spread pods across zones, NetworkPolicy, Pod Security "restricted" on the namespace, and quotas/limits like the lab has.
- **Monitoring:** JSON logs, a `/metrics` endpoint, and alerts based on errors and latency rather than CPU.
- **Ingress:** ingress-nginx has reached end of life, so I'd move to Gateway API (see [ANSWERS.md](ANSWERS.md)).
- **App:** a proper production server (gunicorn or uvicorn) with a fixed number of workers, instead of one thread per connection.

## Repo layout

```
setup.sh, README.md, ANSWERS.md
service/      app.py, test_app.py, Dockerfile, .dockerignore
chart/        Helm chart (Deployment, ConfigMap, Service, Ingress, PDB)
deploy/       saved ingress-nginx manifest used by setup.sh
lab/          the handout lab; scenario.sh and cluster-state/ are unchanged
  broken-chart/      my fixes, one commit per fix
  FINDINGS.md        what I found and how
  part4-session.log  recording of the debugging session
.github/workflows/ci.yml   lint, build, Trivy scan
```

## How I used AI

<!-- TODO(before submitting): re-read this section and edit it so every
     sentence is literally true of what YOU did — what you reviewed, changed,
     and can explain live. Delete this comment afterwards. -->

I used Claude Code (in my terminal) a lot on this, so here's exactly how.

- **Planning:** it read the assignment and suggested a plan and the repo structure.
- **Parts 1, 2, 3, 5 and the CI bonus:** it wrote the first versions of the code, chart, `setup.sh`, the answer and the workflow. I reviewed them, and we tested everything on my machine.
- **Part 4:** it ran the debugging commands in my terminal against my local kind cluster. Everything was recorded with `script`, so `part4-session.log` is the real record, dead ends included. FINDINGS is written from that output.

Things that were wrong at first and got fixed through testing:
- `setup.sh` failed the second time it ran. It waited on ingress-nginx setup Jobs that Kubernetes deletes shortly after they finish. Now it waits for the controller instead.
- After a manual `kubectl patch` of the ConfigMap, Helm 4 refused to upgrade because of an ownership conflict. `setup.sh` now passes `--force-conflicts`.
- My network blocks `raw.githubusercontent.com` and inspects HTTPS traffic. The first guess about which proxy certificate was involved was wrong. I found the right one by looking at the certificate chain, which is why the ingress-nginx manifest is saved in `deploy/` and why `EXTRA_CA_CERT` exists.
- The first resource numbers were guesses. I replaced them with measured ones and lowered the memory request from 64Mi to 32Mi.
- In Part 4, several guesses about the reporter turned out wrong when tested (CPU, emulation, HTTP/2, Kubernetes version, writable folders), and so did a first conclusion that it needed a Content-Length header. A test with a fake API showed the real cause, a fixed 1024-byte read limit. A `--set` value from one test also stuck around in later Helm releases. I caught it with `helm get values` before the final run.
