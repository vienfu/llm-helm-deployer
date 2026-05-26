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

echo "[4/6] ingress + scrape annotation toggles"
out=$(helm template t . -f ci/ingress-values.yaml)
echo "$out" | grep -q "kind: Ingress" || fail "ingress on but not rendered"
out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | grep -q "kind: Ingress"; then fail "ingress off but rendered"; fi
# 监控接入方式已从 ServiceMonitor 改为 Pod annotation；不应再渲染 ServiceMonitor
if echo "$out" | grep -q "kind: ServiceMonitor"; then fail "ServiceMonitor should never be rendered after monitor-simplify"; fi
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."prometheus.io/scrape"' \
  | grep -qx "true" || fail "prometheus.io/scrape=true should default on"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."prometheus.io/port"' \
  | grep -qx "8000" || fail "prometheus.io/port should match vllm.port"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."prometheus.io/path"' \
  | grep -qx "/metrics" || fail "prometheus.io/path should be /metrics"
if echo "$out" | grep -q "grafana_dashboard"; then fail "grafanaDashboard should default off"; fi

# metrics.serviceMonitor.enabled=false 时不应注入 annotation
out_off=$(helm template t . --set metrics.serviceMonitor.enabled=false)
if echo "$out_off" | grep -q "prometheus.io/scrape"; then
  fail "metrics.serviceMonitor.enabled=false but scrape annotation rendered"
fi
pass "annotation-based scrape toggle"

# hostPath path/mountPath transparent
out=$(helm template t . -f ci/default-values.yaml)
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "model-store") | .hostPath.path' \
  | grep -q "/data/models" || fail "hostPath path mismatch"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "model-store") | .mountPath' \
  | grep -q "/models" || fail "hostPath mountPath mismatch"

echo "[5/6] optional subcharts default off; togglable"
out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | grep -q "kind: DaemonSet"; then fail "subcharts default off but DaemonSet rendered"; fi
if echo "$out" | grep -E "kind: Deployment$" | grep -q "prometheus-server"; then
  fail "prometheus subchart default off but server Deployment rendered"
fi
pass "subcharts default off"

# 单独开 dcgm-exporter（最轻），断言其 DaemonSet 出现
out=$(helm template t . -n llm --set 'dcgm-exporter.enabled=true')
echo "$out" | grep -q "kind: DaemonSet" || fail "dcgm-exporter on but DaemonSet not rendered"
pass "dcgm-exporter toggle on"

# prometheus 子 chart 启用：应渲染 prometheus-server Deployment + ConfigMap，
# 且不应启用 alertmanager / pushgateway / node-exporter / kube-state-metrics
out=$(helm template t . -n llm --set 'prometheus.enabled=true')
echo "$out" | yq 'select(.kind == "Deployment") | .metadata.name' \
  | grep -qx "t-prometheus-server" || fail "prometheus on but server Deployment not rendered"
echo "$out" | yq 'select(.kind == "ConfigMap") | .metadata.name' \
  | grep -qx "t-prometheus-server" || fail "prometheus on but server ConfigMap not rendered"
if echo "$out" | yq 'select(.kind == "Deployment") | .metadata.name' | grep -qE 'alertmanager|pushgateway|kube-state-metrics'; then
  fail "prometheus subchart unwanted components enabled"
fi
if echo "$out" | grep -q "kind: DaemonSet"; then
  fail "prometheus subchart node-exporter should be disabled"
fi
pass "prometheus subchart minimal profile"

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

# prometheus 子 chart 不支持 global.imageRegistry，需通过 prometheus.server.image.repository
# 单独覆盖；这里断言"显式覆盖能落到渲染输出"
out=$(helm template t . -n llm \
  --set 'prometheus.enabled=true' \
  --set 'prometheus.server.image.repository=my-reg.io/prometheus/prometheus')
echo "$out" | yq 'select(.kind == "Deployment" and .metadata.name == "t-prometheus-server") | .spec.template.spec.containers[].image' \
  | grep -q "^my-reg.io/prometheus/prometheus" || fail "prometheus.server.image.repository override not honored"
pass "prometheus.server.image.repository override honored"

# 离线镜像清单约束：监控段 = prometheus + config-reloader = 2 行（无 alertmanager/grafana/ksm/node-exporter/operator）
mon_count=$(grep -E '^[^#]' ../tools/images.list | grep -E 'prometheus|grafana|alertmanager|node-exporter|kube-state-metrics' | wc -l | tr -d ' ')
[ "$mon_count" = "2" ] || fail "tools/images.list monitoring image count should be 2 (prometheus + config-reloader), got: $mon_count"
# 不应再出现 KPS 大件
if grep -E '^[^#]' ../tools/images.list | grep -qE 'grafana|alertmanager|node-exporter|kube-state-metrics|prometheus-operator:'; then
  fail "tools/images.list still contains KPS heavy components"
fi
pass "images.list monitoring slice slimmed"

pass "all static tests passed"
