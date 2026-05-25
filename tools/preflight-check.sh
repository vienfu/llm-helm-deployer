#!/usr/bin/env bash
# preflight-check.sh: 集群环境预检（方案 C 离线 bundle 与日常排障两用）。
# 检查项：
#   1. GPU 节点存在且 nvidia.com/gpu 容量 >= MIN_GPU
#   2. ServiceMonitor CRD 已安装（外部 Prometheus Operator 或 kps 子 chart 提供）
#
# 参数：
#   -n, --namespace <ns>     目标命名空间（仅用于权限自检；默认 default）
#   --min-gpu <N>            至少需要的 GPU 总卡数（默认 1）
#   --skip-sm                跳过 ServiceMonitor CRD 检查
#                            （未启用 metrics.serviceMonitor 或将启用 kps 子 chart 时使用）
#   -h, --help               帮助
#
# 退出码：
#   0  全部通过
#   1  存在 FAIL（阻塞性问题，禁止安装）
#   2  仅 WARN（建议关注但不阻塞）
#   3  环境缺工具（kubectl 不可用）

set -uo pipefail

NAMESPACE="default"
MIN_GPU=1
SKIP_SM=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --min-gpu) MIN_GPU="$2"; shift 2 ;;
    --skip-sm) SKIP_SM=1; shift ;;
    -h|--help)
      awk '/^# /{sub(/^# ?/,""); print; next} /^set -uo/{exit}' "$0"
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not installed" >&2; exit 3; }

FAIL=0
WARN=0

red()    { printf "\033[31m%s\033[0m" "$*"; }
green()  { printf "\033[32m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }

ok()   { printf "  [%s] %s\n" "$(green PASS)" "$*"; }
warn() { printf "  [%s] %s\n" "$(yellow WARN)" "$*"; WARN=$((WARN+1)); }
fail() { printf "  [%s] %s\n" "$(red FAIL)" "$*"; FAIL=$((FAIL+1)); }

# kubectl 是否能联到 API Server
if ! kubectl version --request-timeout=3s >/dev/null 2>&1; then
  echo "ERROR: kubectl 无法连接到集群，请检查 kubeconfig" >&2
  exit 3
fi

echo "==> 集群上下文: $(kubectl config current-context 2>/dev/null || echo unknown)"
echo

# === 1. GPU 节点 + nvidia.com/gpu 资源 ===
echo "==> [1/2] GPU 节点检查"

# 列出 nvidia.com/gpu allocatable > 0 的节点
gpu_nodes_json=$(kubectl get nodes -o json 2>/dev/null \
  | jq -c '[.items[] | {
      name: .metadata.name,
      gpu: ((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber),
      ready: ([.status.conditions[] | select(.type=="Ready" and .status=="True")] | length > 0),
      schedulable: ((.spec.unschedulable // false) | not),
      taints: ([.spec.taints[]? | {key,effect}])
    }]' 2>/dev/null || echo "[]")

if [ "${gpu_nodes_json}" = "[]" ] || [ -z "${gpu_nodes_json}" ]; then
  fail "kubectl 未返回任何节点信息（jq 不可用？）"
else
  total_gpu=$(echo "${gpu_nodes_json}" | jq '[.[] | .gpu] | add // 0')
  ready_gpu=$(echo "${gpu_nodes_json}" | jq '[.[] | select(.ready and .schedulable) | .gpu] | add // 0')
  gpu_node_count=$(echo "${gpu_nodes_json}" | jq '[.[] | select(.gpu > 0)] | length')

  if [ "${gpu_node_count}" -eq 0 ]; then
    fail "集群中没有任何节点暴露 nvidia.com/gpu 资源"
    fail "  可能原因：未安装 nvidia-device-plugin（可在本 chart 启用 nvidia-device-plugin.enabled=true）"
  else
    ok "发现 ${gpu_node_count} 个 GPU 节点，allocatable 总计 ${total_gpu} 卡，可调度 ${ready_gpu} 卡"
    # 列出节点明细
    echo "${gpu_nodes_json}" | jq -r '.[] | select(.gpu > 0)
      | "      - \(.name): gpu=\(.gpu) ready=\(.ready) schedulable=\(.schedulable)"'
  fi

  if [ "${ready_gpu}" -lt "${MIN_GPU}" ]; then
    fail "可调度 GPU 数 ${ready_gpu} < 要求 ${MIN_GPU}"
  fi

  # 检查 NoSchedule taint，提示用户配 tolerations
  taint_nodes=$(echo "${gpu_nodes_json}" | jq -r \
    '[.[] | select(.gpu > 0) | select(.taints[]?.effect == "NoSchedule")] | length')
  if [ "${taint_nodes}" -gt 0 ]; then
    warn "${taint_nodes} 个 GPU 节点带 NoSchedule taint，请在 values.yaml 配置 tolerations"
  fi
fi

echo

# === 2. ServiceMonitor CRD ===
echo "==> [2/2] ServiceMonitor CRD 检查"
if [ "${SKIP_SM}" -eq 1 ]; then
  warn "已跳过 ServiceMonitor CRD 检查（--skip-sm）"
else
  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    sm_version=$(kubectl get crd servicemonitors.monitoring.coreos.com \
      -o jsonpath='{.status.storedVersions[0]}' 2>/dev/null || echo unknown)
    ok "servicemonitors.monitoring.coreos.com CRD 已安装（version: ${sm_version}）"

    # 顺带检查 prometheus operator pod 是否运行（可选）
    pop=$(kubectl get pods -A -l app.kubernetes.io/name=prometheus-operator \
      --field-selector=status.phase=Running 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    if [ "${pop}" -eq 0 ]; then
      warn "未发现运行中的 prometheus-operator Pod，ServiceMonitor 可能不会被消费"
      warn "  → 若客户已用其他 label 部署 Operator，可忽略此提醒"
    else
      ok "发现 ${pop} 个运行中的 prometheus-operator Pod"
    fi
  else
    fail "ServiceMonitor CRD 缺失"
    fail "  → 选项 A：--set kube-prometheus-stack.enabled=true 让本 chart 安装 Prometheus Operator + CRDs"
    fail "  → 选项 B：让客户先装 prometheus-operator，再装本 chart"
    fail "  → 选项 C：--set metrics.serviceMonitor.enabled=false 关闭指标采集（不推荐）"
  fi
fi

echo

# === 总结 ===
echo "==> 体检结果: FAIL=${FAIL} WARN=${WARN}"
if [ "${FAIL}" -gt 0 ]; then
  echo "$(red 阻塞性问题存在，请先解决再安装。)"
  exit 1
elif [ "${WARN}" -gt 0 ]; then
  echo "$(yellow 存在告警，请人工确认是否继续。)"
  exit 2
fi
echo "$(green 全部通过 ✓)"
exit 0
