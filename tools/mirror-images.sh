#!/usr/bin/env bash
# 镜像同步脚本：把本 chart（含可选子 chart）依赖的所有公网镜像
# 镜像同步到客户私有 registry，用于离线/内网部署场景。
#
# 用法：
#   DEST_REG=my-reg.io.example/llm ./tools/mirror-images.sh
#   DEST_REG=my-reg.io.example/llm DRY_RUN=1 ./tools/mirror-images.sh
#   DEST_REG=my-reg.io.example/llm USE_SKOPEO=1 ./tools/mirror-images.sh
#
# 环境变量：
#   DEST_REG   目标 registry 前缀（必填，如 my-reg.io/llm）
#   DRY_RUN    设为 1 仅打印命令，不执行
#   USE_SKOPEO 设为 1 使用 skopeo copy（推荐，无需本地 docker daemon）
#              否则使用 docker pull/tag/push
#
# 注意：
#   - 本脚本只搬运公网 → 客户 registry。客户登陆 / 网络通路自行准备。
#   - 默认覆盖到 ${DEST_REG}/<原 path>:<原 tag>，保持路径与 tag 一致。
#   - 子 chart 镜像 tag 跟随 helm dependency 锁定的子 chart AppVersion；
#     若升级子 chart 版本，需同步更新本脚本镜像清单。

set -euo pipefail

if [ -z "${DEST_REG:-}" ]; then
  echo "ERROR: DEST_REG is required, e.g. DEST_REG=my-reg.io.example/llm $0" >&2
  exit 2
fi

# 镜像清单：(<source>) 一行一个
# 主 chart：vLLM 推理镜像 + helm test curl 探针
# 子 chart：从各 chart 默认 values 抓取（与 Chart.lock 锁定的 AppVersion 对齐）
IMAGES=(
  # 主 chart
  "docker.io/vllm/vllm-openai:v0.6.3"
  "docker.io/curlimages/curl:8.10.1"

  # nvidia-device-plugin 0.17.0 (AppVersion 对齐)
  "nvcr.io/nvidia/k8s-device-plugin:v0.17.0"

  # dcgm-exporter 3.4.2 (AppVersion 对齐)
  "nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04"

  # kube-prometheus-stack 65.0.0 (子组件 AppVersion 与上游 values 对齐)
  "quay.io/prometheus/prometheus:v2.54.1"
  "docker.io/grafana/grafana:11.2.2"
  "quay.io/prometheus-operator/prometheus-operator:v0.77.1"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0"
  "quay.io/prometheus/node-exporter:v1.8.2"
)

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY] $*"
  else
    echo "+ $*"
    eval "$@"
  fi
}

# 把 docker.io/foo/bar:tag → ${DEST_REG}/foo/bar:tag
# 其他 registry 同样剥掉 host，保留路径与 tag。
strip_host() {
  local img="$1"
  # 去掉首段 host（含 ':' 或第一个 '/'）
  echo "${img#*/}"
}

if [ "${USE_SKOPEO:-0}" = "1" ]; then
  command -v skopeo >/dev/null || { echo "ERROR: skopeo not installed" >&2; exit 3; }
  for src in "${IMAGES[@]}"; do
    dst_path=$(strip_host "$src")
    dst="${DEST_REG}/${dst_path}"
    run "skopeo copy --all docker://${src} docker://${dst}"
  done
else
  command -v docker >/dev/null || { echo "ERROR: docker not installed (or set USE_SKOPEO=1)" >&2; exit 3; }
  for src in "${IMAGES[@]}"; do
    dst_path=$(strip_host "$src")
    dst="${DEST_REG}/${dst_path}"
    run "docker pull ${src}"
    run "docker tag ${src} ${dst}"
    run "docker push ${dst}"
  done
fi

echo
echo "=== 同步完成。helm install 时使用："
echo "  --set global.imageRegistry=${DEST_REG} \\"
echo "  --set 'global.imagePullSecrets[0].name=<your-pull-secret>'"
echo
echo "注意 nvidia-device-plugin / dcgm-exporter 不接受 global.imageRegistry，"
echo "需要额外覆盖："
echo "  --set 'nvidia-device-plugin.image.repository=${DEST_REG}/nvidia/k8s-device-plugin' \\"
echo "  --set 'dcgm-exporter.image.repository=${DEST_REG}/nvidia/k8s/dcgm-exporter'"
