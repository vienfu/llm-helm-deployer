#!/usr/bin/env bash
# 镜像同步脚本：把本 chart（含可选子 chart）依赖的所有镜像同步到客户私有 registry。
# 支持两种源：
#   1) 默认（公网）：从公网 registry 拉取后推到客户 registry。
#   2) FROM_DIR=<dir>：从 docker-archive tar 文件目录推到客户 registry，
#      用于方案 C 离线 bundle 解压后跑（无需访问公网）。
#
# 用法（密码强制从 stdin 读取，绝不通过 env / 命令行传入）：
#
#   # === 在线模式（方案 B）===
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
#   # nerdctl 模式（containerd 节点，无 docker 时常用）
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot USE_NERDCTL=1 \
#       ./tools/mirror-images.sh
#
#   # podman 模式（RHEL/Rocky/openSUSE 默认）
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot USE_PODMAN=1 \
#       ./tools/mirror-images.sh
#
#   # 自动选择：skopeo > nerdctl > docker > podman（按可用性，无需任何 USE_*）
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot ./tools/mirror-images.sh
#
#   # === 离线模式（方案 C）===
#   # 解压 bundle 后在 bundle 目录下执行（任意一种 CLI 都可）：
#   FROM_DIR=./images USE_NERDCTL=1 \
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot \
#       ./tools/mirror-images.sh
#
# 环境变量：
#   DEST_REG         目标 registry 前缀（必填，如 my-reg.io/llm）
#   DEST_USER        目标 registry 用户名；非空则强制从 stdin 读取密码
#   DEST_TLS_VERIFY  设为 false 时跳过证书校验（自签 / HTTP 私有仓库）
#   FROM_DIR         指定 docker-archive 目录（含 manifest.json），离线 bundle 模式
#   IMAGES_LIST      镜像清单文件路径（默认 tools/images.list，与脚本同目录）
#   SRC_USER         源 registry 用户名（仅在线模式 + 源镜像需要鉴权时，如 nvcr.io NGC API Key）；
#                    非空则强制从 stdin 读取源 registry 密码
#   USE_SKOPEO       设为 1 用 skopeo copy（推荐，无 daemon 依赖）
#   USE_NERDCTL      设为 1 用 nerdctl pull/tag/push（containerd 生态）
#   USE_PODMAN       设为 1 用 podman pull/tag/push
#   USE_DOCKER       设为 1 用 docker pull/tag/push
#   NERDCTL_NAMESPACE  仅 nerdctl 模式生效，默认空；设为 k8s.io 时镜像同步到 kubelet 可见的 namespace
#   DRY_RUN          设为 1 仅打印命令，不执行
#
# 安全策略：
#   - 密码绝不通过环境变量或命令行参数传入，只能通过 stdin。
#   - 交互模式下用 `read -rs`（不回显），并在 tty 上显示提示语。
#   - docker 模式仍走 `docker login --password-stdin`，凭证写入
#     ~/.docker/config.json，脚本退出时自动 logout 释放。
#   - skopeo 模式用 inline --dest-creds，不写 daemon 状态。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_LIST="${IMAGES_LIST:-${SCRIPT_DIR}/images.list}"

if [ -z "${DEST_REG:-}" ]; then
  echo "ERROR: DEST_REG is required, e.g. DEST_REG=my-reg.io.example/llm $0" >&2
  exit 2
fi

# 取 DEST_REG 中的 host 段（首个 '/' 之前）作为 registry 主机
DEST_HOST="${DEST_REG%%/*}"

# === FROM_DIR 模式校验 ===
FROM_DIR="${FROM_DIR:-}"
if [ -n "${FROM_DIR}" ]; then
  [ -d "${FROM_DIR}" ] || { echo "ERROR: FROM_DIR=${FROM_DIR} 不存在" >&2; exit 2; }
  if [ -n "${SRC_USER:-}" ]; then
    echo "WARN: FROM_DIR 模式忽略 SRC_USER（无源 registry 鉴权）" >&2
    SRC_USER=""
  fi
fi

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

# === 加载镜像清单 ===
# 优先：IMAGES_LIST 文件（'#' 注释 + 空行忽略）
# 与 build-bundle.sh 共用同一份 images.list，避免漂移
[ -f "${IMAGES_LIST}" ] || { echo "ERROR: images list not found: ${IMAGES_LIST}" >&2; exit 2; }
# 用 while read 兼容 macOS 自带 bash 3.2（无 mapfile）
IMAGES=()
while IFS= read -r line; do
  [ -n "${line}" ] && IMAGES+=("${line}")
done < <(grep -vE '^[[:space:]]*(#|$)' "${IMAGES_LIST}" | awk '{$1=$1;print}')
[ ${#IMAGES[@]} -gt 0 ] || { echo "ERROR: no images parsed from ${IMAGES_LIST}" >&2; exit 4; }

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY] $*"
  else
    echo "+ $*"
    eval "$@"
  fi
}

# 取镜像名:tag（剥掉所有 registry/path 前缀，只保留最后一段）
# 例：docker.io/vllm/vllm-openai:v0.6.3        → vllm-openai:v0.6.3
# 例：nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5   → dcgm-exporter:3.3.5
# 例：quay.io/prometheus/prometheus:v3.11.3    → prometheus:v3.11.3
# 拼装：${DEST_REG}/${repo_tag}，目标 registry 下扁平化，避免内部多级路径污染
repo_tag() {
  local img="$1"
  echo "${img##*/}"
}

# 与 build-bundle.sh 保持一致的 tar 文件名规则
# 镜像 ref → 安全文件名: 全部小写、'/'→'-'、':'→'-'
safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '/:' '--'
}

# FROM_DIR 模式：根据镜像 ref 找到对应的 tar 文件
# 优先读 manifest.json（精确映射），回退到 safe_name 规则
resolve_archive() {
  local ref="$1"
  if [ -f "${FROM_DIR}/manifest.json" ] && command -v jq >/dev/null 2>&1; then
    local file
    file=$(jq -r --arg ref "${ref}" '.images[] | select(.ref == $ref) | .file' "${FROM_DIR}/manifest.json")
    if [ -n "${file}" ] && [ "${file}" != "null" ]; then
      echo "${FROM_DIR}/${file}"
      return
    fi
  fi
  echo "${FROM_DIR}/$(safe_name "${ref}").tar"
}

# === 鉴权：docker / nerdctl / podman 模式 ===
# 三家 CLI 在 login/logout/pull/tag/push/load 上语法完全兼容，统一封装 ${CLI_TOOL}
# nerdctl 多一个 --namespace 概念（containerd 命名空间，不是 k8s namespace）：
#   - 默认 default；NERDCTL_NAMESPACE=k8s.io 时镜像可被节点 kubelet 直接消费
CLI_TOOL=""
CLI_KIND=""

# 选择 CLI：显式 USE_* > 自动检测（skopeo > nerdctl > docker > podman）
# DRY_RUN=1 模式下不强制要求 CLI 已安装（便于在没装对应工具的机器上预览命令）
select_cli_tool() {
  local need_check=1
  [ "${DRY_RUN:-0}" = "1" ] && need_check=0

  if [ "${USE_SKOPEO:-0}" = "1" ]; then
    [ "${need_check}" = "1" ] && { command -v skopeo >/dev/null || { echo "ERROR: USE_SKOPEO=1 但未安装 skopeo" >&2; exit 3; }; }
    CLI_KIND="skopeo"; CLI_TOOL="skopeo"; return
  fi
  if [ "${USE_NERDCTL:-0}" = "1" ]; then
    [ "${need_check}" = "1" ] && { command -v nerdctl >/dev/null || { echo "ERROR: USE_NERDCTL=1 但未安装 nerdctl" >&2; exit 3; }; }
    CLI_KIND="nerdctl"; CLI_TOOL="nerdctl"; return
  fi
  if [ "${USE_PODMAN:-0}" = "1" ]; then
    [ "${need_check}" = "1" ] && { command -v podman >/dev/null || { echo "ERROR: USE_PODMAN=1 但未安装 podman" >&2; exit 3; }; }
    CLI_KIND="podman"; CLI_TOOL="podman"; return
  fi
  if [ "${USE_DOCKER:-0}" = "1" ]; then
    [ "${need_check}" = "1" ] && { command -v docker >/dev/null || { echo "ERROR: USE_DOCKER=1 但未安装 docker" >&2; exit 3; }; }
    CLI_KIND="docker"; CLI_TOOL="docker"; return
  fi
  # 自动检测：skopeo > nerdctl > docker > podman
  if command -v skopeo >/dev/null; then
    CLI_KIND="skopeo"; CLI_TOOL="skopeo"
  elif command -v nerdctl >/dev/null; then
    CLI_KIND="nerdctl"; CLI_TOOL="nerdctl"
  elif command -v docker >/dev/null; then
    CLI_KIND="docker"; CLI_TOOL="docker"
  elif command -v podman >/dev/null; then
    CLI_KIND="podman"; CLI_TOOL="podman"
  else
    if [ "${need_check}" = "1" ]; then
      echo "ERROR: 未检测到 skopeo / nerdctl / docker / podman 中的任何一个" >&2
      echo "       请安装其中之一，或显式 USE_SKOPEO / USE_NERDCTL / USE_DOCKER / USE_PODMAN=1" >&2
      exit 3
    fi
    # DRY_RUN 兜底
    CLI_KIND="docker"; CLI_TOOL="docker"
  fi
}

# nerdctl 全局参数（namespace），其它 CLI 返回空
cli_global_args() {
  if [ "${CLI_KIND}" = "nerdctl" ] && [ -n "${NERDCTL_NAMESPACE:-}" ]; then
    echo "--namespace=${NERDCTL_NAMESPACE}"
  fi
}

cli_login() {
  local g; g="$(cli_global_args)"
  if [ -n "${DEST_USER:-}" ]; then
    if cli_supports_password_stdin; then
      cli_login_via_stdin
    else
      cli_login_via_authfile
    fi
  else
    echo "WARN: DEST_USER not set; relying on existing ${CLI_KIND} login state for ${DEST_HOST}" >&2
  fi
}

# 检测当前 CLI 是否支持 `login --password-stdin`
# 老旧 docker (<17.07) / 部分裁剪 CLI / 国产引擎可能缺这个 flag
# DRY_RUN 模式下假定支持（避免在没装 CLI 的开发机上误判）
cli_supports_password_stdin() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    return 0
  fi
  ${CLI_TOOL} login --help 2>&1 | grep -q -- '--password-stdin'
}

# 路径 A：标准 stdin 路径
cli_login_via_stdin() {
  local g; g="$(cli_global_args)"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY] ${CLI_TOOL} ${g} login ${DEST_HOST} -u ${DEST_USER} --password-stdin"
  else
    echo "+ ${CLI_TOOL} ${g} login ${DEST_HOST} -u ${DEST_USER} --password-stdin"
    printf "%s" "${DEST_PASS}" | ${CLI_TOOL} ${g} login "${DEST_HOST}" -u "${DEST_USER}" --password-stdin
  fi
  if [ -n "${SRC_USER:-}" ]; then
    for host in nvcr.io quay.io docker.io registry.k8s.io; do
      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[DRY] ${CLI_TOOL} ${g} login ${host} -u ${SRC_USER} --password-stdin"
      else
        printf "%s" "${SRC_PASS}" | ${CLI_TOOL} ${g} login "${host}" -u "${SRC_USER}" --password-stdin || true
      fi
    done
  fi
}

# 路径 B：CLI 不支持 --password-stdin 时，直接写临时 auth 文件
# 既不让密码进入 argv（避免 ps / shell history 泄漏），又能让 push 走鉴权
# - docker / nerdctl 读 ${DOCKER_CONFIG}/config.json
# - podman 读 ${REGISTRY_AUTH_FILE}
# 退出时由 cli_logout trap 清理临时目录
_AUTH_TMP_DIR=""
_AUTH_FILE_PATH=""

# 跨平台 base64：macOS 默认无 -w，Linux GNU 用 -w0；统一用 tr 去换行
_b64_oneline() {
  base64 | tr -d '\n'
}

# 累加一组 auths 到一个 JSON 文件
# 输入：host  user  pass
# 全程通过临时文件 + 文本拼接，不让密码出现在命令行参数里
_write_authfile() {
  local cfg="$1"
  shift
  # 收集 (host user pass) 三元组到数组
  local -a entries=("$@")
  local n=${#entries[@]}
  local i=0
  echo '{' >"${cfg}"
  echo '  "auths": {' >>"${cfg}"
  while [ $i -lt $n ]; do
    local host="${entries[$i]}"
    local user="${entries[$((i+1))]}"
    local pass="${entries[$((i+2))]}"
    local b64
    b64="$(printf "%s" "${user}:${pass}" | _b64_oneline)"
    local sep=","
    [ $((i+3)) -ge $n ] && sep=""
    printf '    "%s": { "auth": "%s" }%s\n' "${host}" "${b64}" "${sep}" >>"${cfg}"
    i=$((i+3))
  done
  echo '  }' >>"${cfg}"
  echo '}' >>"${cfg}"
  chmod 600 "${cfg}"
}

cli_login_via_authfile() {
  echo "INFO: ${CLI_KIND} 不支持 --password-stdin，降级到临时 auth 文件方式" >&2
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY] write auth config (DOCKER_CONFIG / REGISTRY_AUTH_FILE) for ${DEST_HOST} as ${DEST_USER}"
    if [ -n "${SRC_USER:-}" ]; then
      echo "[DRY] write auth config for nvcr.io quay.io docker.io registry.k8s.io as ${SRC_USER}"
    fi
    return 0
  fi

  _AUTH_TMP_DIR="$(mktemp -d -t llm-mirror-XXXXXX 2>/dev/null || mktemp -d /tmp/llm-mirror-XXXXXX)"
  chmod 700 "${_AUTH_TMP_DIR}"
  _AUTH_FILE_PATH="${_AUTH_TMP_DIR}/config.json"

  local -a entries=()
  entries+=("${DEST_HOST}" "${DEST_USER}" "${DEST_PASS}")
  if [ -n "${SRC_USER:-}" ]; then
    entries+=("nvcr.io"          "${SRC_USER}" "${SRC_PASS}")
    entries+=("quay.io"          "${SRC_USER}" "${SRC_PASS}")
    entries+=("docker.io"        "${SRC_USER}" "${SRC_PASS}")
    entries+=("registry.k8s.io"  "${SRC_USER}" "${SRC_PASS}")
  fi
  _write_authfile "${_AUTH_FILE_PATH}" "${entries[@]}"

  case "${CLI_KIND}" in
    docker|nerdctl)
      export DOCKER_CONFIG="${_AUTH_TMP_DIR}"
      echo "+ export DOCKER_CONFIG=${_AUTH_TMP_DIR}  (auth file for ${DEST_HOST})"
      ;;
    podman)
      export REGISTRY_AUTH_FILE="${_AUTH_FILE_PATH}"
      echo "+ export REGISTRY_AUTH_FILE=${_AUTH_FILE_PATH}"
      ;;
    *)
      echo "ERROR: 不支持的 CLI: ${CLI_KIND}" >&2
      exit 3
      ;;
  esac
}

cli_logout() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  local g; g="$(cli_global_args)"
  if [ -n "${DEST_USER:-}" ]; then
    if [ -n "${_AUTH_TMP_DIR}" ] && [ -d "${_AUTH_TMP_DIR}" ]; then
      # 路径 B：清理临时 auth 文件 + 取消 env
      rm -rf "${_AUTH_TMP_DIR}"
      unset DOCKER_CONFIG REGISTRY_AUTH_FILE
    else
      # 路径 A：常规 logout
      ${CLI_TOOL} ${g} logout "${DEST_HOST}" >/dev/null 2>&1 || true
    fi
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

# === 主流程 ===
select_cli_tool
if [ -n "${FROM_DIR}" ]; then
  echo "==> 离线模式 (FROM_DIR=${FROM_DIR}, CLI=${CLI_KIND})"
else
  echo "==> 在线模式 (CLI=${CLI_KIND})"
fi

if [ "${CLI_KIND}" = "skopeo" ]; then
  src_args="$(skopeo_src_args)"
  dst_args="$(skopeo_dest_args)"
  for src in "${IMAGES[@]}"; do
    dst_path=$(repo_tag "$src")
    dst="${DEST_REG}/${dst_path}"
    if [ -n "${FROM_DIR}" ]; then
      archive="$(resolve_archive "${src}")"
      [ -f "${archive}" ] || { echo "ERROR: archive not found: ${archive}" >&2; exit 5; }
      # docker-archive 单 tag 输入；--src-creds 在 archive 模式无意义，故省略
      run "skopeo copy ${dst_args} docker-archive:${archive} docker://${dst}"
    else
      run "skopeo copy --all ${src_args} ${dst_args} docker://${src} docker://${dst}"
    fi
  done
else
  # docker / nerdctl / podman 共用同一组语法
  if [ "${DEST_TLS_VERIFY:-true}" = "false" ]; then
    case "${CLI_KIND}" in
      docker)
        echo "WARN: docker 模式不支持 per-push 跳过 TLS 校验，请预先把 ${DEST_HOST} 加到 docker daemon insecure-registries" >&2 ;;
      nerdctl)
        echo "WARN: nerdctl 模式不支持 per-push 跳过 TLS 校验，请预先把 ${DEST_HOST} 加到 /etc/containerd/certs.d 或 nerdctl --insecure-registry（containerd 配置）" >&2 ;;
      podman)
        echo "WARN: podman 模式请把 ${DEST_HOST} 加到 /etc/containers/registries.conf 的 insecure list" >&2 ;;
    esac
  fi
  cli_login
  trap cli_logout EXIT
  g="$(cli_global_args)"
  for src in "${IMAGES[@]}"; do
    dst_path=$(repo_tag "$src")
    dst="${DEST_REG}/${dst_path}"
    if [ -n "${FROM_DIR}" ]; then
      archive="$(resolve_archive "${src}")"
      [ -f "${archive}" ] || { echo "ERROR: archive not found: ${archive}" >&2; exit 5; }
      # load 后 image 仍以原 ref 出现在本地，再 tag + push
      run "${CLI_TOOL} ${g} load -i ${archive}"
      run "${CLI_TOOL} ${g} tag ${src} ${dst}"
      run "${CLI_TOOL} ${g} push ${dst}"
    else
      run "${CLI_TOOL} ${g} pull ${src}"
      run "${CLI_TOOL} ${g} tag ${src} ${dst}"
      run "${CLI_TOOL} ${g} push ${dst}"
    fi
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
echo "需要额外覆盖（注意：扁平化后路径不再保留原 registry 内的多级目录）："
echo "  --set 'nvidia-device-plugin.image.repository=${DEST_REG}/k8s-device-plugin' \\"
echo "  --set 'dcgm-exporter.image.repository=${DEST_REG}/dcgm-exporter'"
