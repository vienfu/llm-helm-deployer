#!/usr/bin/env bash
# install.sh: 离线 bundle 一键入口（方案 C）。
#
# 假定脚本在 bundle 解压后的根目录运行：
#
#   tar xzf llm-deployer-bundle-<ver>.tar.gz
#   cd llm-deployer-bundle-<ver>
#   ./install.sh --dest-reg my-reg.io/llm --dest-user ci-bot \
#       -n llm --release my-llm --create-pull-secret
#
# 编排步骤：
#   [1/5] 校验 SHA256SUMS（可 --skip-sha 跳过）
#   [2/5] preflight-check.sh（可 --skip-preflight 跳过）
#   [3/5] mirror-images.sh（FROM_DIR=./images；可 --skip-mirror 跳过）
#   [4/5] 可选创建 imagePullSecret（--create-pull-secret）
#   [5/5] helm upgrade --install
#
# 安全策略：
#   - 仅在需要时（--dest-user 非空）一次性提示「请输入镜像仓库密码」
#   - 密码不进 env、不进命令行；通过 stdin 喂给 mirror-images.sh，
#     通过 here-doc YAML 创建 imagePullSecret
#
# 参数：
#   -n, --namespace <ns>        命名空间（默认 llm）
#   --release <name>            helm release 名（默认 my-llm）
#   --dest-reg <prefix>         必填，目标 registry 前缀，如 my-reg.io/llm
#   --dest-user <user>          目标 registry 用户名；非空则交互式读密码
#   --dest-tls-verify <bool>    传给 mirror（true|false，默认 true）
#   --pull-secret <name>        imagePullSecret 名（默认 llm-pull-secret）
#   --create-pull-secret        在 namespace 内创建/更新 pull secret
#   --use-skopeo                mirror 用 skopeo（默认 docker）
#   --values <file>             附加 -f <file>（可重复）
#   --set <kv>                  附加 --set kv（可重复）
#   --skip-sha                  跳过 SHA256SUMS 校验
#   --skip-preflight            跳过 preflight
#   --skip-mirror               跳过镜像同步
#   --dry-run                   仅打印命令，不执行
#   -h, --help                  帮助

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# bundle 根目录默认就是 install.sh 所在目录
BUNDLE_ROOT="${SCRIPT_DIR}"

NAMESPACE="llm"
RELEASE="my-llm"
DEST_REG=""
DEST_USER=""
DEST_TLS_VERIFY="true"
PULL_SECRET="llm-pull-secret"
CREATE_PULL_SECRET=0
USE_SKOPEO=0
SKIP_SHA=0
SKIP_PREFLIGHT=0
SKIP_MIRROR=0
DRY_RUN=0
EXTRA_VALUES=()
EXTRA_SETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)        NAMESPACE="$2"; shift 2 ;;
    --release)             RELEASE="$2"; shift 2 ;;
    --dest-reg)            DEST_REG="$2"; shift 2 ;;
    --dest-user)           DEST_USER="$2"; shift 2 ;;
    --dest-tls-verify)     DEST_TLS_VERIFY="$2"; shift 2 ;;
    --pull-secret)         PULL_SECRET="$2"; shift 2 ;;
    --create-pull-secret)  CREATE_PULL_SECRET=1; shift ;;
    --use-skopeo)          USE_SKOPEO=1; shift ;;
    --values)              EXTRA_VALUES+=("$2"); shift 2 ;;
    --set)                 EXTRA_SETS+=("$2"); shift 2 ;;
    --skip-sha)            SKIP_SHA=1; shift ;;
    --skip-preflight)      SKIP_PREFLIGHT=1; shift ;;
    --skip-mirror)         SKIP_MIRROR=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)
      awk '/^# /{sub(/^# ?/,""); print; next} /^set -uo/{exit}' "$0"
      exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "${DEST_REG}" ] || { echo "ERROR: --dest-reg 必填" >&2; exit 2; }

DEST_HOST="${DEST_REG%%/*}"

# === 工具检查 ===
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: 缺少工具: $1" >&2; exit 3; }; }
require helm
require kubectl
require tar
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
  || { echo "ERROR: 缺少工具: sha256sum 或 shasum" >&2; exit 3; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

run() {
  if [ "${DRY_RUN}" -eq 1 ]; then echo "[DRY] $*"; else echo "+ $*"; eval "$@"; fi
}

# === 一次性读取密码（仅当 --dest-user 给了才提示）===
DEST_PASS=""
if [ -n "${DEST_USER}" ]; then
  if [ -t 0 ]; then
    printf "请输入镜像仓库密码 (用户 %s@%s): " "${DEST_USER}" "${DEST_HOST}" >&2
    IFS= read -rs DEST_PASS
    printf "\n" >&2
  else
    IFS= read -r DEST_PASS || true
  fi
  [ -n "${DEST_PASS}" ] || { echo "ERROR: 密码为空，已取消" >&2; exit 4; }
fi

echo
echo "==> bundle 根目录: ${BUNDLE_ROOT}"
echo "    namespace    : ${NAMESPACE}"
echo "    release      : ${RELEASE}"
echo "    dest-reg     : ${DEST_REG}"
echo "    dest-user    : ${DEST_USER:-<none>}"
echo "    pull-secret  : ${PULL_SECRET} (create=${CREATE_PULL_SECRET})"
echo "    dry-run      : ${DRY_RUN}"
echo

# === [1/5] SHA256SUMS 校验 ===
echo "==> [1/5] 校验 SHA256SUMS"
if [ "${SKIP_SHA}" -eq 1 ]; then
  echo "    已跳过（--skip-sha）"
elif [ ! -f "${BUNDLE_ROOT}/SHA256SUMS" ]; then
  echo "WARN: 未找到 SHA256SUMS，跳过校验" >&2
else
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "${BUNDLE_ROOT}" && sha256sum -c SHA256SUMS --quiet ) \
      || { echo "ERROR: SHA256SUMS 校验失败，bundle 可能损坏" >&2; exit 5; }
  else
    # macOS shasum -c 对相对路径敏感，逐行验
    fail=0
    while read -r expected file; do
      [ -z "${file}" ] && continue
      actual=$(shasum -a 256 "${BUNDLE_ROOT}/${file}" 2>/dev/null | awk '{print $1}')
      [ "${expected}" = "${actual}" ] || { echo "  FAIL: ${file}"; fail=1; }
    done < "${BUNDLE_ROOT}/SHA256SUMS"
    [ "${fail}" -eq 0 ] || { echo "ERROR: SHA256SUMS 校验失败" >&2; exit 5; }
  fi
  echo "    全部文件校验通过"
fi
echo

# === [2/5] preflight ===
echo "==> [2/5] 集群预检"
if [ "${SKIP_PREFLIGHT}" -eq 1 ]; then
  echo "    已跳过（--skip-preflight）"
else
  PRE="${BUNDLE_ROOT}/tools/preflight-check.sh"
  [ -x "${PRE}" ] || { echo "ERROR: 找不到 ${PRE}" >&2; exit 2; }
  set +e
  "${PRE}" -n "${NAMESPACE}"
  pre_rc=$?
  set -e
  case "${pre_rc}" in
    0) echo "    preflight 全部通过" ;;
    2) echo "    preflight 存在 WARN，继续（如需中止请 Ctrl-C）" ;;
    *) echo "ERROR: preflight 失败 (rc=${pre_rc})，请先解决再重试" >&2; exit 1 ;;
  esac
fi
echo

# === [3/5] mirror images ===
echo "==> [3/5] 同步镜像到 ${DEST_REG}"
if [ "${SKIP_MIRROR}" -eq 1 ]; then
  echo "    已跳过（--skip-mirror）"
else
  MIR="${BUNDLE_ROOT}/tools/mirror-images.sh"
  [ -x "${MIR}" ] || { echo "ERROR: 找不到 ${MIR}" >&2; exit 2; }
  mirror_env=(
    "FROM_DIR=${BUNDLE_ROOT}/images"
    "DEST_REG=${DEST_REG}"
    "DEST_TLS_VERIFY=${DEST_TLS_VERIFY}"
    "IMAGES_LIST=${BUNDLE_ROOT}/tools/images.list"
  )
  [ -n "${DEST_USER}" ]    && mirror_env+=("DEST_USER=${DEST_USER}")
  [ "${USE_SKOPEO}" -eq 1 ] && mirror_env+=("USE_SKOPEO=1")
  [ "${DRY_RUN}" -eq 1 ]   && mirror_env+=("DRY_RUN=1")

  if [ -n "${DEST_USER}" ]; then
    # 通过 stdin 把已读到的密码喂给 mirror-images.sh
    printf "%s\n" "${DEST_PASS}" | env "${mirror_env[@]}" "${MIR}"
  else
    env "${mirror_env[@]}" "${MIR}" </dev/null
  fi
fi
echo

# === [4/5] 创建 imagePullSecret（可选）===
echo "==> [4/5] 创建/更新 imagePullSecret"
if [ "${CREATE_PULL_SECRET}" -ne 1 ]; then
  echo "    已跳过（未传 --create-pull-secret）"
elif [ -z "${DEST_USER}" ]; then
  echo "WARN: 未提供 --dest-user，无法创建 pull secret，跳过" >&2
else
  # 先确保 namespace 存在
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY] kubectl create namespace ${NAMESPACE}"
    echo "[DRY] kubectl -n ${NAMESPACE} apply -f - <<<dockerconfigjson(${PULL_SECRET})"
  else
    kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 \
      || kubectl create namespace "${NAMESPACE}" >/dev/null
    # 用 here-doc 构造 dockerconfigjson；密码不出现在命令行参数 / ps
    auth=$(printf '%s:%s' "${DEST_USER}" "${DEST_PASS}" | base64 | tr -d '\n')
    dockercfg=$(printf '{"auths":{"%s":{"username":"%s","auth":"%s"}}}' \
      "${DEST_HOST}" "${DEST_USER}" "${auth}" | base64 | tr -d '\n')
    kubectl -n "${NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: ${PULL_SECRET}
data:
  .dockerconfigjson: ${dockercfg}
EOF
    unset auth dockercfg
    echo "    已创建/更新 secret/${PULL_SECRET} on ns/${NAMESPACE}"
  fi
fi
echo

# === [5/5] helm upgrade --install ===
echo "==> [5/5] helm upgrade --install ${RELEASE}"
chart_tgz=$(ls "${BUNDLE_ROOT}/chart/"*.tgz 2>/dev/null | head -n 1)
[ -n "${chart_tgz}" ] || { echo "ERROR: ${BUNDLE_ROOT}/chart 下没有 .tgz" >&2; exit 2; }
echo "    chart: ${chart_tgz}"

helm_args=(
  "upgrade" "--install" "${RELEASE}" "${chart_tgz}"
  "-n" "${NAMESPACE}" "--create-namespace"
  "--set" "global.imageRegistry=${DEST_REG}"
)
if [ "${CREATE_PULL_SECRET}" -eq 1 ] && [ -n "${DEST_USER}" ]; then
  helm_args+=("--set" "global.imagePullSecrets[0].name=${PULL_SECRET}")
fi
for f in ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"}; do helm_args+=("-f" "${f}"); done
for kv in ${EXTRA_SETS[@]+"${EXTRA_SETS[@]}"}; do helm_args+=("--set" "${kv}"); done

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY] helm ${helm_args[*]}"
else
  echo "+ helm ${helm_args[*]}"
  helm "${helm_args[@]}"
fi

# 清理敏感变量
unset DEST_PASS

echo
echo "=== DONE ==="
echo "查看状态: kubectl -n ${NAMESPACE} get pods,svc -l app.kubernetes.io/instance=${RELEASE}"
echo "查看日志: kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/instance=${RELEASE} -f"
