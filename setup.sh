#!/usr/bin/env bash
# One-command, idempotent setup: kind cluster "demo" -> ingress-nginx ->
# build + load image -> helm release "demo" in namespace "demo".
#
#   ./setup.sh            # safe to re-run; every step converges, none recreates
#
# Overridable via env:  CLUSTER_NAME, HTTP_PORT, HTTPS_PORT, KIND_NODE_IMAGE
#   EXTRA_CA_CERT=/path/ca.pem  trust an extra root CA inside the kind node, for
#                               networks that intercept TLS (corporate proxies);
#                               without it containerd cannot pull images there.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-demo}"
RELEASE="demo"
NAMESPACE="demo"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
INGRESS_NGINX_VERSION="controller-v1.15.1"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Vendored copy of the upstream kind manifest for this exact version (images
# are digest-pinned inside it). Reviewed once, applied offline, no surprises.
INGRESS_NGINX_MANIFEST="$ROOT/deploy/ingress-nginx-kind-${INGRESS_NGINX_VERSION}.yaml"
CTX="kind-${CLUSTER_NAME}"
# Every kubectl/helm call is pinned to the kind context, so this script can
# never touch whatever cluster your kubeconfig happens to point at.
K() { kubectl --context "$CTX" "$@"; }

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. prerequisites ---------------------------------------------------------
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is not installed or not on PATH"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
[ -f "$INGRESS_NGINX_MANIFEST" ] || die "missing $INGRESS_NGINX_MANIFEST"
if [ -n "${EXTRA_CA_CERT:-}" ]; then
  [ -f "$EXTRA_CA_CERT" ] || die "EXTRA_CA_CERT=$EXTRA_CA_CERT does not exist"
  EXTRA_CA_CERT="$(cd "$(dirname "$EXTRA_CA_CERT")" && pwd)/$(basename "$EXTRA_CA_CERT")"
fi

# Image name/tag come from the chart's values.yaml so the image we build is
# exactly what the chart (and any `helm upgrade --set ...` later) references.
IMAGE_REPO="$(awk '/^image:/{f=1;next} f&&/^[^ ]/{f=0} f&&$1=="repository:"{print $2}' "$ROOT/chart/values.yaml" | tr -d '"')"
IMAGE_TAG="$(awk '/^image:/{f=1;next} f&&/^[^ ]/{f=0} f&&$1=="tag:"{print $2}' "$ROOT/chart/values.yaml" | tr -d '"')"
[ -n "$IMAGE_REPO" ] && [ -n "$IMAGE_TAG" ] || die "could not read image.repository/tag from chart/values.yaml"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"

# --- 1. kind cluster (create or reuse) ----------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists — reusing it"
else
  CA_MOUNT=""
  if [ -n "${EXTRA_CA_CERT:-}" ]; then
    CA_MOUNT="    extraMounts:
      - hostPath: ${EXTRA_CA_CERT}
        containerPath: /usr/local/share/ca-certificates/extra-ca.crt
        readOnly: true"
  fi
  log "creating kind cluster '$CLUSTER_NAME' (host ports ${HTTP_PORT}/${HTTPS_PORT} -> ingress)"
  kind create cluster --name "$CLUSTER_NAME" ${KIND_NODE_IMAGE:+--image "$KIND_NODE_IMAGE"} --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: ${HTTP_PORT}
        protocol: TCP
      - containerPort: 443
        hostPort: ${HTTPS_PORT}
        protocol: TCP
${CA_MOUNT}
EOF
fi
if [ -n "${EXTRA_CA_CERT:-}" ]; then
  NODE="${CLUSTER_NAME}-control-plane"
  if ! docker exec "$NODE" test -e /etc/ssl/certs/extra-ca.pem 2>/dev/null; then
    docker exec "$NODE" test -f /usr/local/share/ca-certificates/extra-ca.crt \
      || die "cluster exists without EXTRA_CA_CERT mounted; run 'kind delete cluster --name $CLUSTER_NAME' and re-run"
    log "trusting EXTRA_CA_CERT inside $NODE and restarting containerd"
    docker exec "$NODE" update-ca-certificates >/dev/null
    docker exec "$NODE" systemctl restart containerd
    sleep 5
  fi
fi
K cluster-info >/dev/null || die "cannot reach cluster via context $CTX"

# --- 2. ingress-nginx ---------------------------------------------------------
log "installing ingress-nginx ${INGRESS_NGINX_VERSION} from vendored manifest (kubectl apply is idempotent)"
K apply -f "$INGRESS_NGINX_MANIFEST"
# Don't `kubectl wait` on the admission Jobs: upstream sets
# ttlSecondsAfterFinished, so on a re-run they are garbage-collected mid-wait
# and the wait fails with NotFound (found by running this script twice).
# The controller rollout is what matters; the helm retry below absorbs the
# few seconds before the validating webhook starts answering.
log "waiting for the ingress-nginx controller"
K -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

# --- 3. build and load the image ----------------------------------------------
log "building image ${IMAGE}"
docker build -t "$IMAGE" "$ROOT/service"
log "loading ${IMAGE} into kind cluster '$CLUSTER_NAME'"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# --- 4. helm release ----------------------------------------------------------
# The controller can report Ready a few seconds before its validating webhook
# answers, so retry the install a few times instead of failing on that race.
#
# Helm 4 uses server-side apply. If someone `kubectl patch`ed an object (e.g.
# the ConfigMap), that field manager now owns those fields and a plain upgrade
# fails with "Apply failed with N conflicts". The chart is the source of truth,
# so force our ownership back. Helm 3 has no such flag (and no such conflict).
HELM_EXTRA=()
if helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'; then
  HELM_EXTRA+=(--force-conflicts)
fi
log "installing chart as release '$RELEASE' in namespace '$NAMESPACE'"
for attempt in 1 2 3 4 5; do
  if helm --kube-context "$CTX" upgrade --install "$RELEASE" "$ROOT/chart" \
       --namespace "$NAMESPACE" --create-namespace --wait --timeout 180s \
       ${HELM_EXTRA[@]+"${HELM_EXTRA[@]}"}; then
    break
  fi
  [ "$attempt" -eq 5 ] && die "helm upgrade failed after $attempt attempts"
  echo "helm attempt $attempt failed — retrying in 10s"; sleep 10
done

# --- 5. smoke test ------------------------------------------------------------
HOST="$(awk '/^ingress:/{f=1;next} f&&/^[^ ]/{f=0} f&&$1=="host:"{print $2}' "$ROOT/chart/values.yaml" | tr -d '"')"
log "smoke test through the ingress (Host: ${HOST})"
for i in $(seq 1 30); do
  if body="$(curl -fsS -m 3 -H "Host: ${HOST}" "http://localhost:${HTTP_PORT}/" 2>/dev/null)"; then
    echo "$body"; break
  fi
  [ "$i" -eq 30 ] && die "service did not answer through the ingress"
  sleep 2
done

cat <<EOF

Done. Verify with:
  kubectl --context $CTX -n $NAMESPACE get pods,svc,ingress
  curl -s -H 'Host: ${HOST}' http://localhost:${HTTP_PORT}/
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: ${HOST}' http://localhost:${HTTP_PORT}/healthz
EOF
