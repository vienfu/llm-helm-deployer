#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/../manifests" && pwd)"
cd "$CHART_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"
}
require helm
require yq

echo "[1/4] helm lint on all ci scenarios"
for f in ci/*-values.yaml; do
  helm lint . -f "$f" >/dev/null
  pass "lint $f"
done

echo "[2/4] tensorParallelSize=2 should sync nvidia.com/gpu and --tensor-parallel-size"
out=$(helm template t . -f ci/tp2-values.yaml)
gpu=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits."nvidia.com/gpu"')
[ "$gpu" = "2" ] || fail "expected gpu=2, got $gpu"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--tensor-parallel-size" || fail "args missing --tensor-parallel-size"
pass "tp2 sync"

echo "[3/4] auth.apiKey present should produce Secret + env + --api-key; absent should not"
out=$(helm template t . -f ci/auth-values.yaml)
echo "$out" | yq 'select(.kind == "Secret")' | grep -q api-key || fail "auth: missing Secret"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' \
  | grep -q VLLM_API_KEY || fail "auth: missing VLLM_API_KEY env"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--api-key" || fail "auth: missing --api-key arg"
pass "auth on"

out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | yq 'select(.kind == "Secret")' | grep -q api-key; then
  fail "auth off but Secret rendered"
fi
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--api-key" && fail "auth off but --api-key rendered"
pass "auth off"

echo "[4/4] ingress + servicemonitor toggles"
out=$(helm template t . -f ci/ingress-values.yaml)
echo "$out" | grep -q "kind: Ingress" || fail "ingress on but not rendered"
out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | grep -q "kind: Ingress"; then fail "ingress off but rendered"; fi
echo "$out" | grep -q "kind: ServiceMonitor" || fail "ServiceMonitor should default on"
if echo "$out" | grep -q "grafana_dashboard"; then fail "grafanaDashboard should default off"; fi

# hostPath path/mountPath transparent
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "model-store") | .hostPath.path' \
  | grep -q "/data/models" || fail "hostPath path mismatch"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "model-store") | .mountPath' \
  | grep -q "/models" || fail "hostPath mountPath mismatch"

pass "all static tests passed"
