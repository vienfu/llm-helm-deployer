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
#   --log-file <path>           自定义日志路径（默认 ${BUNDLE}/install-<ts>.log）
#   --no-log                    不写日志文件
#   -v, --verbose               额外打印调试信息（kubectl/helm 上下文、文件清单等）
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
VERBOSE=0
NO_LOG=0
LOG_FILE=""
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
    --log-file)            LOG_FILE="$2"; shift 2 ;;
    --no-log)              NO_LOG=1; shift ;;
    -v|--verbose)          VERBOSE=1; shift ;;
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

# === 日志辅助 ===
# log 级别：INFO / WARN / ERROR / DEBUG（DEBUG 仅 -v 时打印）
# 所有日志带 ISO-8601 时间戳；同时透出到 stderr 与 LOG_FILE（若启用）
_ts()    { date "+%Y-%m-%dT%H:%M:%S%z"; }
log()    { printf '[%s] [%s] %s\n' "$(_ts)" "INFO"  "$*"; }
warn()   { printf '[%s] [%s] %s\n' "$(_ts)" "WARN"  "$*" >&2; }
err()    { printf '[%s] [%s] %s\n' "$(_ts)" "ERROR" "$*" >&2; }
debug()  { [ "${VERBOSE}" -eq 1 ] && printf '[%s] [%s] %s\n' "$(_ts)" "DEBUG" "$*" || true; }

# 启用文件日志：把 stdout/stderr 同时 tee 到 LOG_FILE。
# 跳过条件：--no-log / --dry-run（dry-run 通常排查脚本逻辑，不写盘）
if [ "${NO_LOG}" -ne 1 ] && [ "${DRY_RUN}" -ne 1 ]; then
  if [ -z "${LOG_FILE}" ]; then
    LOG_FILE="${BUNDLE_ROOT}/install-$(date +%Y%m%d-%H%M%S).log"
  fi
  # 先确保父目录存在；失败则降级为不写日志
  if mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null; then
    # 用 tee 把 stdout/stderr 都落盘。注意：不要 tee 包含密码的密钥块。
    exec > >(tee -a "${LOG_FILE}") 2>&1
    log "日志写入: ${LOG_FILE}"
  else
    LOG_FILE=""
    warn "无法创建日志目录，已禁用文件日志"
  fi
fi

# 阶段计时
_stage_begin() { STAGE_NAME="$1"; STAGE_START=$(date +%s); log "==> $1 开始"; }
_stage_end()   {
  local dur=$(( $(date +%s) - STAGE_START ))
  log "==> ${STAGE_NAME} 完成（耗时 ${dur}s）"
}

# 退出钩子：失败时打印当前阶段与日志路径，便于客户回报
on_exit() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    err "脚本在 ${STAGE_NAME:-<init>} 阶段以 rc=${rc} 退出"
    [ -n "${LOG_FILE}" ] && err "完整日志见: ${LOG_FILE}"
  fi
  exit "${rc}"
}
trap on_exit EXIT

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

# verbose: 额外打印环境上下文，便于客户回报 issue
if [ "${VERBOSE}" -eq 1 ]; then
  debug "shell: ${BASH_VERSION:-?} | uname: $(uname -a)"
  debug "helm version: $(helm version --short 2>/dev/null || echo unknown)"
  debug "kubectl version: $(kubectl version --client --short 2>/dev/null \
                           || kubectl version --client -o json 2>/dev/null \
                           | awk -F'"' '/gitVersion/{print $4; exit}' \
                           || echo unknown)"
  debug "kubectl context: $(kubectl config current-context 2>/dev/null || echo unknown)"
  debug "use-skopeo: ${USE_SKOPEO}  dest-tls-verify: ${DEST_TLS_VERIFY}"
  debug "skip: sha=${SKIP_SHA} preflight=${SKIP_PREFLIGHT} mirror=${SKIP_MIRROR}"
  debug "extra-values: ${EXTRA_VALUES[*]:-<none>}"
  debug "extra-sets:   ${EXTRA_SETS[*]:-<none>}"
fi
echo

# === [1/5] SHA256SUMS 校验 ===
echo "==> [1/5] 校验 SHA256SUMS"
_stage_begin "[1/5] sha256"
if [ "${SKIP_SHA}" -eq 1 ]; then
  log "    已跳过（--skip-sha）"
elif [ ! -f "${BUNDLE_ROOT}/SHA256SUMS" ]; then
  warn "未找到 SHA256SUMS，跳过校验"
else
  sums_count=$(wc -l < "${BUNDLE_ROOT}/SHA256SUMS" | tr -d ' ')
  log "    校验 ${sums_count} 个文件..."
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "${BUNDLE_ROOT}" && sha256sum -c SHA256SUMS --quiet ) \
      || { err "SHA256SUMS 校验失败，bundle 可能损坏"; exit 5; }
  else
    # macOS shasum -c 对相对路径敏感，逐行验
    fail=0
    while read -r expected file; do
      [ -z "${file}" ] && continue
      actual=$(shasum -a 256 "${BUNDLE_ROOT}/${file}" 2>/dev/null | awk '{print $1}')
      [ "${expected}" = "${actual}" ] || { err "  FAIL: ${file}"; fail=1; }
    done < "${BUNDLE_ROOT}/SHA256SUMS"
    [ "${fail}" -eq 0 ] || { err "SHA256SUMS 校验失败"; exit 5; }
  fi
  log "    全部文件校验通过"
fi
_stage_end
echo

# === [2/5] preflight ===
echo "==> [2/5] 集群预检"
_stage_begin "[2/5] preflight"
if [ "${SKIP_PREFLIGHT}" -eq 1 ]; then
  log "    已跳过（--skip-preflight）"
else
  PRE="${BUNDLE_ROOT}/tools/preflight-check.sh"
  [ -x "${PRE}" ] || { err "找不到 ${PRE}"; exit 2; }
  set +e
  "${PRE}" -n "${NAMESPACE}"
  pre_rc=$?
  set -e
  case "${pre_rc}" in
    0) log "    preflight 全部通过" ;;
    2) warn "    preflight 存在 WARN，继续（如需中止请 Ctrl-C）" ;;
    *) err "preflight 失败 (rc=${pre_rc})，请先解决再重试"; exit 1 ;;
  esac
fi
_stage_end
echo

# === [3/5] mirror images ===
echo "==> [3/5] 同步镜像到 ${DEST_REG}"
_stage_begin "[3/5] mirror"
if [ "${SKIP_MIRROR}" -eq 1 ]; then
  log "    已跳过（--skip-mirror）"
else
  MIR="${BUNDLE_ROOT}/tools/mirror-images.sh"
  IMG_DIR="${BUNDLE_ROOT}/images"
  IMG_LIST="${BUNDLE_ROOT}/tools/images.list"
  [ -x "${MIR}" ]      || { err "找不到 ${MIR}"; exit 2; }
  [ -d "${IMG_DIR}" ]  || { err "找不到 images 目录: ${IMG_DIR}"; exit 2; }
  [ -f "${IMG_LIST}" ] || { err "找不到 images list: ${IMG_LIST}"; exit 2; }

  # 统计待推镜像数 / 现存 archive 数 / 总大小，便于客户预估时长
  img_count=$(grep -cvE '^[[:space:]]*(#|$)' "${IMG_LIST}" 2>/dev/null || echo 0)
  archive_count=$(find "${IMG_DIR}" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l | tr -d ' ')
  if [ -d "${IMG_DIR}" ]; then
    total_size=$(du -sh "${IMG_DIR}" 2>/dev/null | awk '{print $1}')
  else
    total_size="?"
  fi
  log "    清单镜像数: ${img_count}"
  log "    本地 archive: ${archive_count} 个，总大小 ${total_size}"
  log "    目标 registry: ${DEST_REG} (tls-verify=${DEST_TLS_VERIFY}, use-skopeo=${USE_SKOPEO})"
  if [ "${VERBOSE}" -eq 1 ]; then
    debug "镜像清单："
    grep -vE '^[[:space:]]*(#|$)' "${IMG_LIST}" | sed 's/^/      - /' || true
    debug "archive 文件："
    find "${IMG_DIR}" -maxdepth 1 -name '*.tar' -exec basename {} \; 2>/dev/null \
      | sort | sed 's/^/      - /' || true
  fi

  # 大小不一致提醒（清单 7 个但本地 5 个 archive，往往是 build-bundle 部分失败）
  if [ "${archive_count}" -gt 0 ] && [ "${archive_count}" -lt "${img_count}" ]; then
    warn "本地 archive 数 (${archive_count}) < 清单数 (${img_count})，部分镜像将走 archive 缺失分支"
  fi

  mirror_env=(
    "FROM_DIR=${IMG_DIR}"
    "DEST_REG=${DEST_REG}"
    "DEST_TLS_VERIFY=${DEST_TLS_VERIFY}"
    "IMAGES_LIST=${IMG_LIST}"
  )
  [ -n "${DEST_USER}" ]     && mirror_env+=("DEST_USER=${DEST_USER}")
  [ "${USE_SKOPEO}" -eq 1 ] && mirror_env+=("USE_SKOPEO=1")
  [ "${DRY_RUN}" -eq 1 ]    && mirror_env+=("DRY_RUN=1")
  debug "mirror env: ${mirror_env[*]}"

  # 调用 mirror-images.sh，不让其失败导致整个脚本 ERR trap 触发两次
  set +e
  if [ -n "${DEST_USER}" ]; then
    printf "%s\n" "${DEST_PASS}" | env "${mirror_env[@]}" "${MIR}"
  else
    env "${mirror_env[@]}" "${MIR}" </dev/null
  fi
  mir_rc=$?
  set -e
  if [ "${mir_rc}" -ne 0 ]; then
    err "mirror-images.sh 失败 (rc=${mir_rc})"
    case "${mir_rc}" in
      2) err "  → 参数 / 路径错误：检查 FROM_DIR 与 IMAGES_LIST" ;;
      3) err "  → 缺工具：USE_SKOPEO=1 但未安装 skopeo，或未启用 USE_SKOPEO 但缺 docker" ;;
      4) err "  → 密码为空" ;;
      5) err "  → archive 缺失：可能 bundle 不完整或 images.list 与 build 时不一致" ;;
    esac
    exit "${mir_rc}"
  fi
  log "    镜像同步完成"
fi
_stage_end
echo

# === [4/5] 创建 imagePullSecret（可选）===
echo "==> [4/5] 创建/更新 imagePullSecret"
_stage_begin "[4/5] pull-secret"
if [ "${CREATE_PULL_SECRET}" -ne 1 ]; then
  log "    已跳过（未传 --create-pull-secret）"
elif [ -z "${DEST_USER}" ]; then
  warn "未提供 --dest-user，无法创建 pull secret，跳过"
else
  log "    目标 secret  : ${PULL_SECRET}"
  log "    namespace    : ${NAMESPACE}"
  log "    docker-server: ${DEST_HOST}"
  log "    docker-user  : ${DEST_USER}"
  log "    密码长度     : ${#DEST_PASS} 字符（已脱敏）"

  # 先确保 namespace 存在
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY] kubectl create namespace ${NAMESPACE}"
    echo "[DRY] kubectl -n ${NAMESPACE} apply -f - <<<dockerconfigjson(${PULL_SECRET})"
  else
    if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
      log "    namespace ${NAMESPACE} 已存在"
    else
      log "    namespace ${NAMESPACE} 不存在，创建中"
      kubectl create namespace "${NAMESPACE}" >/dev/null
      log "    namespace ${NAMESPACE} 创建成功"
    fi

    # 已存在则 apply 即更新；先看一眼是否冲突
    if kubectl -n "${NAMESPACE}" get secret "${PULL_SECRET}" >/dev/null 2>&1; then
      existing_type=$(kubectl -n "${NAMESPACE}" get secret "${PULL_SECRET}" \
                       -o jsonpath='{.type}' 2>/dev/null || echo "")
      if [ "${existing_type}" != "kubernetes.io/dockerconfigjson" ]; then
        err "已存在的 secret/${PULL_SECRET} 类型为 ${existing_type:-<unknown>}，"
        err "  与目标 dockerconfigjson 冲突；请手动删除或换 --pull-secret 名"
        exit 1
      fi
      log "    secret/${PULL_SECRET} 已存在 (type=${existing_type})，将更新"
    else
      log "    secret/${PULL_SECRET} 不存在，将创建"
    fi

    # 用 here-doc 构造 dockerconfigjson；密码不出现在命令行参数 / ps
    auth=$(printf '%s:%s' "${DEST_USER}" "${DEST_PASS}" | base64 | tr -d '\n')
    dockercfg=$(printf '{"auths":{"%s":{"username":"%s","auth":"%s"}}}' \
      "${DEST_HOST}" "${DEST_USER}" "${auth}" | base64 | tr -d '\n')

    set +e
    apply_out=$(kubectl -n "${NAMESPACE}" apply -f - <<EOF 2>&1
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: ${PULL_SECRET}
data:
  .dockerconfigjson: ${dockercfg}
EOF
    )
    apply_rc=$?
    set -e
    unset auth dockercfg
    if [ "${apply_rc}" -ne 0 ]; then
      err "kubectl apply secret 失败 (rc=${apply_rc})"
      err "  ${apply_out}"
      exit "${apply_rc}"
    fi
    # apply_out 形如 "secret/llm-pull-secret created" 或 "... configured"
    log "    ${apply_out}"

    # 校验：再 get 一次确认 secret 真的可用
    if kubectl -n "${NAMESPACE}" get secret "${PULL_SECRET}" \
         -o jsonpath='{.data.\.dockerconfigjson}' >/dev/null 2>&1; then
      log "    secret/${PULL_SECRET} 校验通过"
    else
      warn "secret/${PULL_SECRET} 创建后再次 get 失败，请手动确认"
    fi
  fi
fi
_stage_end
echo

# === [5/5] helm upgrade --install ===
echo "==> [5/5] helm upgrade --install ${RELEASE}"
_stage_begin "[5/5] helm"
chart_tgz=$(ls "${BUNDLE_ROOT}/chart/"*.tgz 2>/dev/null | head -n 1)
[ -n "${chart_tgz}" ] || { err "${BUNDLE_ROOT}/chart 下没有 .tgz"; exit 2; }
chart_size=$(du -sh "${chart_tgz}" 2>/dev/null | awk '{print $1}')
log "    chart        : ${chart_tgz} (${chart_size})"
log "    release      : ${RELEASE}"
log "    namespace    : ${NAMESPACE}"
log "    imageRegistry: ${DEST_REG}"

# 校验 --values 指定的文件存在；不存在直接失败，避免 helm 报含糊错误
for f in ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"}; do
  [ -f "${f}" ] || { err "values 文件不存在: ${f}"; exit 2; }
  log "    values file  : ${f}"
done
for kv in ${EXTRA_SETS[@]+"${EXTRA_SETS[@]}"}; do
  log "    set          : ${kv}"
done

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
  set +e
  helm "${helm_args[@]}"
  helm_rc=$?
  set -e
  if [ "${helm_rc}" -ne 0 ]; then
    err "helm upgrade --install 失败 (rc=${helm_rc})"
    err "  排查思路："
    err "    - kubectl -n ${NAMESPACE} get events --sort-by=.lastTimestamp | tail -20"
    err "    - kubectl -n ${NAMESPACE} describe pod -l app.kubernetes.io/instance=${RELEASE}"
    err "    - helm -n ${NAMESPACE} history ${RELEASE}"
    exit "${helm_rc}"
  fi
  log "    helm 执行成功"
fi
_stage_end

# 清理敏感变量
unset DEST_PASS

echo
echo "=== DONE ==="
echo "查看状态: kubectl -n ${NAMESPACE} get pods,svc -l app.kubernetes.io/instance=${RELEASE}"
echo "查看日志: kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/instance=${RELEASE} -f"
if [ -n "${LOG_FILE}" ]; then echo "安装日志: ${LOG_FILE}"; fi
exit 0
