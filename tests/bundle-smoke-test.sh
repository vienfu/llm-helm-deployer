#!/usr/bin/env bash
# bundle-smoke-test.sh: 离线 bundle 静态冒烟测试（方案 C）。
#
# 不依赖真实的 K8s / skopeo / docker daemon / 公网拉镜像，
# 通过伪造 bundle 目录 + DRY_RUN 验证 install.sh / mirror-images.sh / preflight-check.sh
# 三件套的契约：参数解析、退出码、关键命令拼接、安全约束。
#
# 跑法：
#   ./tests/bundle-smoke-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${REPO_ROOT}/tools"
TMP_DIR="$(mktemp -d -t bundle-smoke-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

run_capture() {
  # $1: 描述; 余下: 命令
  local desc="$1"; shift
  local out
  set +e
  out=$("$@" 2>&1)
  local rc=$?
  set -e
  printf '%s\n' "${out}"
  return ${rc}
}

assert_contains() {
  local out="$1" needle="$2" desc="$3"
  if echo "${out}" | grep -qF -- "${needle}"; then
    pass "${desc}"
  else
    fail "${desc}（缺少: '${needle}'）"
  fi
}

assert_not_contains() {
  local out="$1" needle="$2" desc="$3"
  if echo "${out}" | grep -qF -- "${needle}"; then
    fail "${desc}（不应出现: '${needle}'）"
  else
    pass "${desc}"
  fi
}

assert_rc() {
  local actual="$1" expected="$2" desc="$3"
  if [ "${actual}" = "${expected}" ]; then
    pass "${desc} (rc=${actual})"
  else
    fail "${desc} (rc=${actual}, expected ${expected})"
  fi
}

# === 准备伪 bundle ===
# 注意：images.list 内置固定清单，与用户本地 tools/images.list 解耦，
# 避免开发者本地注释/裁剪镜像清单时影响测试断言（vllm 等核心镜像必须命中）。
FIXTURE_IMAGES_LIST="docker.io/vllm/vllm-openai:v0.6.3
docker.io/curlimages/curl:8.10.1
quay.io/prometheus/prometheus:v3.11.3
docker.io/grafana/grafana:12.3.1
quay.io/kiwigrid/k8s-sidecar:2.5.0"

make_fake_bundle() {
  local root="$1"
  rm -rf "${root}"
  mkdir -p "${root}"/{chart,images,tools}
  cp "${TOOLS_DIR}/mirror-images.sh"   "${root}/tools/"
  cp "${TOOLS_DIR}/preflight-check.sh" "${root}/tools/"
  printf '%s\n' "${FIXTURE_IMAGES_LIST}" > "${root}/tools/images.list"
  cp "${TOOLS_DIR}/install.sh"         "${root}/install.sh"
  chmod +x "${root}/install.sh" "${root}/tools/"*.sh
  : > "${root}/chart/llm-helm-deployer-0.1.0.tgz"
  # 为 images.list 中每个镜像生成一个空 archive
  while IFS= read -r img; do
    [ -z "${img}" ] && continue
    local f
    f=$(echo "${img}" | tr '[:upper:]' '[:lower:]' | tr '/:' '--').tar
    : > "${root}/images/${f}"
  done < <(grep -vE '^[[:space:]]*(#|$)' "${root}/tools/images.list")
}

echo "==> [1/4] mirror-images.sh 语法 + 参数契约"
bash -n "${TOOLS_DIR}/mirror-images.sh" \
  && pass "bash -n mirror-images.sh" \
  || fail "bash -n mirror-images.sh"

# 缺 DEST_REG → exit 2
out=$(run_capture "" "${TOOLS_DIR}/mirror-images.sh" </dev/null); rc=$?
assert_rc "${rc}" "2" "mirror: 缺 DEST_REG 应 exit 2"
assert_contains "${out}" "DEST_REG" "mirror: 缺 DEST_REG 错误信息含 DEST_REG"

# FROM_DIR 不存在 → exit 2
out=$(FROM_DIR=/no/such/dir DEST_REG=r/llm DRY_RUN=1 \
  "${TOOLS_DIR}/mirror-images.sh" 2>&1 </dev/null); rc=$?
assert_rc "${rc}" "2" "mirror: FROM_DIR 不存在应 exit 2"

# FROM_DIR 缺 archive → exit 5（用空目录）
empty_dir="${TMP_DIR}/empty"; mkdir -p "${empty_dir}"
out=$(FROM_DIR="${empty_dir}" DEST_REG=r/llm DRY_RUN=1 \
  "${TOOLS_DIR}/mirror-images.sh" 2>&1 </dev/null); rc=$?
assert_rc "${rc}" "5" "mirror: FROM_DIR 缺 archive 应 exit 5"

echo
echo "==> [2/4] preflight-check.sh 语法 + 参数"
bash -n "${TOOLS_DIR}/preflight-check.sh" \
  && pass "bash -n preflight-check.sh" \
  || fail "bash -n preflight-check.sh"

out=$(run_capture "" "${TOOLS_DIR}/preflight-check.sh" --help); rc=$?
assert_rc "${rc}" "0" "preflight: --help 应 exit 0"
assert_contains "${out}" "preflight-check.sh" "preflight: --help 输出含脚本名"
assert_contains "${out}" "ServiceMonitor" "preflight: --help 描述含 ServiceMonitor"

echo
echo "==> [3/4] install.sh 语法 + 参数契约"
bash -n "${TOOLS_DIR}/install.sh" \
  && pass "bash -n install.sh" \
  || fail "bash -n install.sh"

# 缺 --dest-reg → exit 2
out=$(run_capture "" "${TOOLS_DIR}/install.sh" </dev/null); rc=$?
assert_rc "${rc}" "2" "install: 缺 --dest-reg 应 exit 2"

# --help → exit 0 + 含关键章节
out=$(run_capture "" "${TOOLS_DIR}/install.sh" --help); rc=$?
assert_rc "${rc}" "0" "install: --help 应 exit 0"
assert_contains "${out}" "[1/5]" "install: --help 含编排步骤"
assert_contains "${out}" "--dest-reg" "install: --help 含 --dest-reg"
assert_contains "${out}" "--create-pull-secret" "install: --help 含 --create-pull-secret"

# 未知参数 → exit 2
out=$(run_capture "" "${TOOLS_DIR}/install.sh" --not-a-real-flag 2>&1); rc=$?
assert_rc "${rc}" "2" "install: 未知参数应 exit 2"

echo
echo "==> [4/4] install.sh 端到端 dry-run（伪 bundle）"
BUNDLE="${TMP_DIR}/bundle"
make_fake_bundle "${BUNDLE}"
[ -f "${BUNDLE}/install.sh" ] && pass "fake bundle 创建成功" || fail "fake bundle 缺 install.sh"

# 4a. 全跳过 + dry-run，验证 helm 命令拼接
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  -n llm --release my-llm \
  --skip-sha --skip-preflight --skip-mirror --dry-run \
  --set vllm.tensorParallelSize=2); rc=$?
assert_rc "${rc}" "0" "install: 全跳过 dry-run 退出码 0"
assert_contains "${out}" "[DRY] helm upgrade --install my-llm" "install: helm upgrade --install 命令"
assert_contains "${out}" "global.imageRegistry=my-reg.io/llm" "install: 透传 global.imageRegistry"
assert_contains "${out}" "vllm.tensorParallelSize=2" "install: 透传 --set"
assert_contains "${out}" "--create-namespace" "install: 含 --create-namespace"
# 没传 --create-pull-secret → 不应出现 imagePullSecrets[0].name
assert_not_contains "${out}" "global.imagePullSecrets[0].name" \
  "install: 未传 --create-pull-secret 时不渲染 imagePullSecrets"

# 4b. 跑到 [3] 镜像同步（FROM_DIR 走 docker load 链；不传 --skip-mirror）
# 显式 --use-docker 锁定到 docker 分支，避免 macOS 自动选到 skopeo 后无法命中 docker load 断言
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --use-docker \
  --skip-sha --skip-preflight --dry-run); rc=$?
assert_rc "${rc}" "0" "install: 含 mirror 的完整 dry-run 退出码 0"
# 用 awk 抽 [3/5] 段
mirror_section=$(printf '%s\n' "${out}" | awk '/\[3\/5\]/,/\[4\/5\]/')
assert_contains "${mirror_section}" "离线模式 (FROM_DIR=" "install→mirror: FROM_DIR 模式"
assert_contains "${mirror_section}" "[DRY] docker  load -i" "install→mirror: docker load 链"
assert_contains "${mirror_section}" "docker.io/vllm/vllm-openai:v0.6.3" "install→mirror: 含核心 vllm 镜像"
assert_contains "${mirror_section}" "my-reg.io/llm/vllm-openai:v0.6.3" "install→mirror: 重写到目标 registry（扁平化）"
assert_not_contains "${mirror_section}" "my-reg.io/llm/vllm/vllm-openai:v0.6.3" \
  "install→mirror: 不再保留源 registry 内的多级目录"

# 4b'. nerdctl 模式 dry-run，验证 CLI 切换 + namespace 注入
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --use-nerdctl \
  --skip-sha --skip-preflight --dry-run); rc=$?
assert_rc "${rc}" "0" "install: --use-nerdctl dry-run 退出码 0"
mirror_section=$(printf '%s\n' "${out}" | awk '/\[3\/5\]/,/\[4\/5\]/')
assert_contains "${mirror_section}" "[DRY] nerdctl  load -i" "install→mirror: nerdctl load 链"
assert_contains "${mirror_section}" "my-reg.io/llm/vllm-openai:v0.6.3" "install→mirror: nerdctl 也走扁平路径"

# 4b''. --use-* 互斥校验
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --use-docker --use-nerdctl \
  --skip-sha --skip-preflight --skip-mirror --dry-run 2>&1); rc=$?
assert_rc "${rc}" "2" "install: --use-docker 与 --use-nerdctl 互斥应 exit 2"

# 4c. SHA256SUMS 缺失应 WARN 而非 FAIL（不阻塞）
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --skip-preflight --skip-mirror --dry-run); rc=$?
assert_rc "${rc}" "0" "install: SHA256SUMS 缺失走 WARN 不阻塞"
assert_contains "${out}" "未找到 SHA256SUMS" "install: SHA256SUMS 缺失提示"

# 4d. SHA256SUMS 损坏应 exit 5
echo "deadbeef  install.sh" > "${BUNDLE}/SHA256SUMS"
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --skip-preflight --skip-mirror --dry-run 2>&1); rc=$?
assert_rc "${rc}" "5" "install: SHA256SUMS 校验失败应 exit 5"
rm -f "${BUNDLE}/SHA256SUMS"

# 4e. chart 目录无 .tgz → exit 2
rm -f "${BUNDLE}/chart/"*.tgz
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --skip-sha --skip-preflight --skip-mirror --dry-run 2>&1); rc=$?
assert_rc "${rc}" "2" "install: chart/ 无 .tgz 应 exit 2"

# 重建 bundle，准备 4f 用例（grafana 镜像）
make_fake_bundle "${BUNDLE}"

# 4f. grafana 镜像在 bundle 中应被 mirror 一并打包/推送
# 验证：dry-run 输出包含 grafana/grafana 与 k8s-sidecar 的 pull/tag/push 三连
# 注：mirror-images.sh 是 bundle-level 行为，不依赖 helm 是否启用 grafana；
# 只要 images.list 列了 grafana 镜像，三件套就该一并 mirror。
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --use-docker \
  --skip-sha --skip-preflight --dry-run); rc=$?
assert_rc "${rc}" "0" "install→mirror(grafana): dry-run 退出码 0"
mirror_section=$(printf '%s\n' "${out}" | awk '/\[3\/5\]/,/\[4\/5\]/')
assert_contains "${mirror_section}" "docker.io/grafana/grafana:12.3.1" \
  "install→mirror(grafana): 含 grafana/grafana:12.3.1 源镜像"
assert_contains "${mirror_section}" "my-reg.io/llm/grafana:12.3.1" \
  "install→mirror(grafana): grafana 重写到目标 registry（扁平化）"
assert_contains "${mirror_section}" "quay.io/kiwigrid/k8s-sidecar:2.5.0" \
  "install→mirror(grafana): 含 k8s-sidecar 源镜像"
assert_contains "${mirror_section}" "my-reg.io/llm/k8s-sidecar:2.5.0" \
  "install→mirror(grafana): k8s-sidecar 重写到目标 registry（扁平化）"

# 4g. 关闭 grafana 不应影响 mirror（mirror 段是 bundle-level，与 helm 开关解耦）
# 这里通过 --set 透传 helm value，但 mirror 阶段早于 helm，所以 grafana 镜像仍会被 mirror。
# 此用例仅验证：透传 --set grafana.enabled=false 不破坏 dry-run 流程。
out=$(run_capture "" "${BUNDLE}/install.sh" \
  --dest-reg my-reg.io/llm \
  --use-docker \
  --skip-sha --skip-preflight --skip-mirror --dry-run \
  --set grafana.enabled=false); rc=$?
assert_rc "${rc}" "0" "install: --set grafana.enabled=false dry-run 退出码 0"
assert_contains "${out}" "grafana.enabled=false" "install: --set grafana.enabled=false 透传到 helm 命令"

echo
echo "==> 结果: PASS=${PASS} FAIL=${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
