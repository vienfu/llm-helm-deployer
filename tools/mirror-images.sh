#!/usr/bin/env bash
# 镜像同步脚本：把本 chart（含可选子 chart）依赖的所有公网镜像
# 镜像同步到客户私有 registry，用于离线/内网部署场景。
#
# 用法（密码强制从 stdin 读取，绝不通过 env / 命令行传入）：
#
#   # 交互式：脚本会提示「请输入镜像仓库密码:」
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot \
#       ./tools/mirror-images.sh
#
#   # CI 管道喂入（非 tty 时直接 read 一行）
#   echo "$REG_PASSWORD" | DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot \
#       ./tools/mirror-images.sh
#
#   # 自签证书 / HTTP 私有仓库
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot DEST_TLS_VERIFY=false \
#       ./tools/mirror-images.sh
#
#   # 干跑（仍会要求输入密码以验证流程一致；如不输任何账号则跳过鉴权）
#   DEST_REG=my-reg.io.example/llm DRY_RUN=1 ./tools/mirror-images.sh
#
#   # skopeo 模式（推荐，无需本地 docker daemon）
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot USE_SKOPEO=1 \
#       ./tools/mirror-images.sh
#
# 环境变量：
#   DEST_REG         目标 registry 前缀（必填，如 my-reg.io/llm）
#   DEST_USER        目标 registry 用户名；非空则强制从 stdin 读取密码
#   DEST_TLS_VERIFY  设为 false 时跳过证书校验（自签 / HTTP 私有仓库）
#   SRC_USER         源 registry 用户名（仅当源镜像需要鉴权时，如 nvcr.io NGC API Key）；
#                    非空则强制从 stdin 读取源 registry 密码
#   USE_SKOPEO       设为 1 用 skopeo copy（推荐）；否则 docker pull/tag/push
#   DRY_RUN          设为 1 仅打印命令，不执行
#
# 安全策略：
#   - 密码绝不通过环境变量或命令行参数传入，只能通过 stdin。
#   - 交互模式下用 `read -rs`（不回显），并在 tty 上显示提示语。
#   - docker 模式仍走 `docker login --password-stdin`，凭证写入
#     ~/.docker/config.json，脚本退出时自动 logout 释放。
#   - skopeo 模式用 inline --dest-creds，不写 daemon 状态。

set -euo pipefail

if [ -z "${DEST_REG:-}" ]; then
  echo "ERROR: DEST_REG is required, e.g. DEST_REG=my-reg.io.example/llm $0" >&2
  exit 2
fi

# 取 DEST_REG 中的 host 段（首个 '/' 之前）作为 registry 主机
DEST_HOST="${DEST_REG%%/*}"

# 强制从 stdin 读取密码，不接受任何 env / 参数注入
# - tty 模式：先打印提示语到 stderr（不污染 stdout），再 read -rs 不回显
# - 非 tty（管道）模式：直接 read 一行，不打印提示语
DEST_PASS=""
SRC_PASS=""

prompt_password() {
  # $1: 提示语；$2: 是否允许为空（空则允许，非空则必填）
  local prompt="$1"
  local var=""
  if [ -t 0 ]; then
    # 交互式终端：提示 + 关闭回显
    printf "%s" "${prompt}" >&2
    IFS= read -rs var
    printf "\n" >&2
  else
    # 管道：直接读一行（CI 场景）
    IFS= read -r var || true
  fi
  echo "${var}"
}

if [ -n "${DEST_USER:-}" ]; then
  DEST_PASS="$(prompt_password "请输入镜像仓库密码 (用户 ${DEST_USER}@${DEST_HOST}): ")"
  if [ -z "${DEST_PASS}" ]; then
    echo "ERROR: 目标 registry 密码为空，已取消" >&2
    exit 4
  fi
fi

if [ -n "${SRC_USER:-}" ]; then
  SRC_PASS="$(prompt_password "请输入源镜像仓库密码 (用户 ${SRC_USER}): ")"
  if [ -z "${SRC_PASS}" ]; then
    echo "ERROR: 源 registry 密码为空，已取消" >&2
    exit 4
  fi
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

# === 鉴权：docker 模式 ===
docker_login() {
  if [ -n "${DEST_USER:-}" ]; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY] docker login ${DEST_HOST} -u ${DEST_USER} --password-stdin"
    else
      echo "+ docker login ${DEST_HOST} -u ${DEST_USER} --password-stdin"
      printf "%s" "${DEST_PASS}" | docker login "${DEST_HOST}" -u "${DEST_USER}" --password-stdin
    fi
  else
    echo "WARN: DEST_USER not set; relying on existing docker login state for ${DEST_HOST}" >&2
  fi
  # 源 registry 鉴权（少见，例如 nvcr.io 私有仓 / 速率限）
  if [ -n "${SRC_USER:-}" ]; then
    for host in nvcr.io quay.io docker.io registry.k8s.io; do
      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[DRY] docker login ${host} -u ${SRC_USER} --password-stdin"
      else
        printf "%s" "${SRC_PASS}" | docker login "${host}" -u "${SRC_USER}" --password-stdin || true
      fi
    done
  fi
}

docker_logout() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -n "${DEST_USER:-}" ]; then
    docker logout "${DEST_HOST}" >/dev/null 2>&1 || true
  fi
}

# === 鉴权：skopeo 模式 ===
# skopeo 用 inline --src-creds / --dest-creds，不写 daemon 状态，更安全
skopeo_dest_args() {
  local args=""
  if [ -n "${DEST_USER:-}" ]; then
    args="${args} --dest-creds ${DEST_USER}:${DEST_PASS}"
  fi
  if [ "${DEST_TLS_VERIFY:-true}" = "false" ]; then
    args="${args} --dest-tls-verify=false"
  fi
  echo "${args}"
}

skopeo_src_args() {
  local args=""
  if [ -n "${SRC_USER:-}" ]; then
    args="${args} --src-creds ${SRC_USER}:${SRC_PASS}"
  fi
  echo "${args}"
}

if [ "${USE_SKOPEO:-0}" = "1" ]; then
  command -v skopeo >/dev/null || { echo "ERROR: skopeo not installed" >&2; exit 3; }
  src_args="$(skopeo_src_args)"
  dst_args="$(skopeo_dest_args)"
  for src in "${IMAGES[@]}"; do
    dst_path=$(strip_host "$src")
    dst="${DEST_REG}/${dst_path}"
    run "skopeo copy --all ${src_args} ${dst_args} docker://${src} docker://${dst}"
  done
else
  command -v docker >/dev/null || { echo "ERROR: docker not installed (or set USE_SKOPEO=1)" >&2; exit 3; }
  if [ "${DEST_TLS_VERIFY:-true}" = "false" ]; then
    echo "WARN: docker 模式不支持 per-push 跳过 TLS 校验，请预先把 ${DEST_HOST} 加到 docker daemon insecure-registries" >&2
  fi
  docker_login
  trap docker_logout EXIT
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
echo "若集群尚未创建 pull secret，可执行（用同一对账号密码）："
echo "  kubectl -n llm create secret docker-registry <your-pull-secret> \\"
echo "    --docker-server=${DEST_HOST} \\"
echo "    --docker-username='<USER>' --docker-password='<PASS>'"
echo
echo "注意 nvidia-device-plugin / dcgm-exporter 不接受 global.imageRegistry，"
echo "需要额外覆盖："
echo "  --set 'nvidia-device-plugin.image.repository=${DEST_REG}/nvidia/k8s-device-plugin' \\"
echo "  --set 'dcgm-exporter.image.repository=${DEST_REG}/nvidia/k8s/dcgm-exporter'"
