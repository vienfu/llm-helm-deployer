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

# 子 chart tarball 不入 git，需先按 Chart.yaml 拉取（Chart.lock 仍生效，update 会复用）
helm dependency update . >/dev/null 2>&1
pass "deps fetched"

echo "[1/6] helm lint on all ci scenarios"
for f in ci/*-values.yaml; do
  helm lint . -f "$f" >/dev/null
  pass "lint $f"
done

echo "[2/6] tensorParallelSize=2 should sync nvidia.com/gpu and --tensor-parallel-size"
out=$(helm template t . -f ci/tp2-values.yaml)
gpu=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits."nvidia.com/gpu"')
[ "$gpu" = "2" ] || fail "expected gpu=2, got $gpu"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--tensor-parallel-size" || fail "args missing --tensor-parallel-size"
pass "tp2 sync"

# schedulerName 默认空 → 不渲染；显式设值 → 出现
out=$(helm template t . -f ci/default-values.yaml)
sched=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.schedulerName')
[ "$sched" = "null" ] || fail "schedulerName should be absent by default, got: $sched"
out=$(helm template t . --set schedulerName=volcano)
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.schedulerName' \
  | grep -qx "volcano" || fail "schedulerName=volcano not rendered"
pass "schedulerName toggle"

echo "[3/6] auth.apiKey present should produce Secret + env + --api-key; absent should not"
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

echo "[4/6] ingress + servicemonitor toggles"
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

echo "[5/6] optional subcharts default off; togglable"
out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | grep -q "kind: DaemonSet"; then fail "subcharts default off but DaemonSet rendered"; fi
if echo "$out" | grep -q "kind: Prometheus$"; then fail "kube-prometheus-stack default off but Prometheus CR rendered"; fi
pass "subcharts default off"

# 单独开 dcgm-exporter（最轻），断言其 DaemonSet 出现
out=$(helm template t . -n llm --set 'dcgm-exporter.enabled=true')
echo "$out" | grep -q "kind: DaemonSet" || fail "dcgm-exporter on but DaemonSet not rendered"
pass "dcgm-exporter toggle on"

# 联动 1：kps 开启时 ServiceMonitor 自动带 release=<name>，且用户标签优先
out=$(helm template t . -n llm --set 'kube-prometheus-stack.enabled=true' --set 'kube-prometheus-stack.crds.enabled=false')
echo "$out" | yq 'select(.kind == "ServiceMonitor" and .metadata.name == "t-llm-helm-deployer") | .metadata.labels.release' \
  | grep -qx "t" || fail "kps on but ServiceMonitor missing release=t label"
pass "ServiceMonitor auto release label when kps on"

out=$(helm template t . -n llm --set 'kube-prometheus-stack.enabled=true' --set 'kube-prometheus-stack.crds.enabled=false' --set 'metrics.serviceMonitor.labels.release=foo')
echo "$out" | yq 'select(.kind == "ServiceMonitor" and .metadata.name == "t-llm-helm-deployer") | .metadata.labels.release' \
  | grep -qx "foo" || fail "user release label override did not win"
pass "user release label override wins"

echo "[6/6] global.imageRegistry / global.imagePullSecrets 离线场景透传"
# 默认：无前缀
out=$(helm template t . -f ci/default-values.yaml)
img=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image')
[ "$img" = "vllm/vllm-openai:v0.6.3" ] || fail "default image should be vllm/vllm-openai:v0.6.3, got: $img"
pass "global.imageRegistry empty => no prefix"

# 设置 global.imageRegistry：主镜像加前缀
out=$(helm template t . --set global.imageRegistry=my-reg.io)
img=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image')
[ "$img" = "my-reg.io/vllm/vllm-openai:v0.6.3" ] || fail "expected prefixed image, got: $img"
pass "global.imageRegistry prefixes vLLM image"

# imagePullSecrets 合并：主 chart + global 同时给值
out=$(helm template t . --set 'imagePullSecrets[0].name=mc' --set 'global.imagePullSecrets[0].name=gc')
secrets=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.imagePullSecrets[].name' | tr '\n' ' ')
echo "$secrets" | grep -q "mc" || fail "imagePullSecrets missing main chart entry: $secrets"
echo "$secrets" | grep -q "gc" || fail "imagePullSecrets missing global entry: $secrets"
pass "imagePullSecrets merge main+global"

# kps 子 chart 接收主 chart global（依赖 helm 原生 global 自动下发）
out=$(helm template t . -n llm \
  --set 'kube-prometheus-stack.enabled=true' \
  --set 'kube-prometheus-stack.crds.enabled=false' \
  --set global.imageRegistry=my-reg.io 2>&1 || true)
# kps 内组件镜像应带 my-reg.io 前缀（任一组件命中即可）
echo "$out" | grep -E 'image:\s*"?my-reg\.io/' >/dev/null || fail "global.imageRegistry not propagated to kube-prometheus-stack"
pass "global.imageRegistry propagates to kube-prometheus-stack"

pass "all static tests passed"
