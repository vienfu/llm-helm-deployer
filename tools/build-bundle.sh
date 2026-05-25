#!/usr/bin/env bash
# build-bundle.sh: 构建完整离线 bundle（方案 C）。
# 输出 dist/llm-deployer-bundle-${VERSION}.tar.gz，结构如下：
#
#   bundle/
#   ├── chart/llm-helm-deployer-<chart-version>.tgz
#   ├── images/
#   │   ├── manifest.json   (镜像名 → tar 文件 → SHA256)
#   │   └── *.tar           (skopeo docker-archive 格式)
#   ├── tools/
#   │   ├── mirror-images.sh
#   │   ├── preflight-check.sh
#   │   └── images.list
#   ├── install.sh                    (一键入口)
#   ├── values-bundle-example.yaml
#   ├── README-OFFLINE.md
#   └── SHA256SUMS
#
# 依赖：helm, skopeo, jq, sha256sum (or shasum), tar
# 用法：
#   ./tools/build-bundle.sh                # 默认输出到 ./dist/
#   OUT_DIR=/tmp/out ./tools/build-bundle.sh
#   ./tools/build-bundle.sh --version 0.1.0-rc1   # 覆盖默认（取自 Chart.yaml）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${REPO_ROOT}/manifests"
IMAGES_LIST="${SCRIPT_DIR}/images.list"

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"
VERSION_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION_OVERRIDE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      awk '/^# /{sub(/^# ?/,""); print; next} /^set -euo/{exit}' "$0"
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# === 工具检查 ===
require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing tool: $1" >&2; exit 3; }
}
require helm
require skopeo
require jq
require tar

# 跨平台 sha256
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    # macOS: shasum -a 256
    shasum -a 256 "$@"
  fi
}

# === 解析版本 ===
CHART_VERSION="$(awk '/^version:/{print $2; exit}' "${CHART_DIR}/Chart.yaml")"
APP_VERSION="$(awk '/^appVersion:/{gsub(/"/,"",$2); print $2; exit}' "${CHART_DIR}/Chart.yaml")"
VERSION="${VERSION_OVERRIDE:-${CHART_VERSION}}"

BUNDLE_NAME="llm-deployer-bundle-${VERSION}"
BUILD_DIR="${OUT_DIR}/${BUNDLE_NAME}"
TARBALL="${OUT_DIR}/${BUNDLE_NAME}.tar.gz"

echo "==> Building bundle"
echo "    chart version : ${CHART_VERSION}"
echo "    app version   : ${APP_VERSION}"
echo "    bundle version: ${VERSION}"
echo "    out dir       : ${OUT_DIR}"
echo

rm -rf "${BUILD_DIR}" "${TARBALL}"
mkdir -p "${BUILD_DIR}"/{chart,images,tools}

# === 1. 打包 chart（含 vendor 的子 chart tarball）===
echo "==> [1/5] helm package"
helm dependency update "${CHART_DIR}" >/dev/null
helm package "${CHART_DIR}" -d "${BUILD_DIR}/chart" >/dev/null
ls "${BUILD_DIR}/chart"

# === 2. 拉取镜像到 docker-archive ===
echo
echo "==> [2/5] skopeo copy images → docker-archive"
# 仅保留非空非注释行
mapfile -t IMAGES < <(grep -vE '^\s*(#|$)' "${IMAGES_LIST}")
[ ${#IMAGES[@]} -gt 0 ] || { echo "ERROR: no images in ${IMAGES_LIST}" >&2; exit 4; }

# 镜像 ref → 安全文件名: 全部小写、'/'→'-'、':'→'-'
safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '/:' '--'
}

manifest_entries=()
for src in "${IMAGES[@]}"; do
  name="$(safe_name "${src}").tar"
  dest="${BUILD_DIR}/images/${name}"
  echo "    + ${src}"
  echo "      → ${name}"
  # --all 保留多架构 manifest；docker-archive 不支持多架构，需用 oci-archive 才完全保留，
  # 但 docker load / containerd 兼容 docker-archive 更广，这里取兼容性优先。
  skopeo copy --override-os linux --override-arch amd64 \
    "docker://${src}" "docker-archive:${dest}:${src}" >/dev/null
  manifest_entries+=("${src}|${name}")
done

# === 3. 生成 images/manifest.json ===
echo
echo "==> [3/5] write images/manifest.json + SHA256"
{
  echo '{'
  echo '  "version": "'"${VERSION}"'",'
  echo '  "format": "docker-archive",'
  echo '  "arch": "amd64",'
  echo '  "images": ['
  last_idx=$(( ${#manifest_entries[@]} - 1 ))
  for i in "${!manifest_entries[@]}"; do
    entry="${manifest_entries[$i]}"
    src="${entry%%|*}"
    name="${entry##*|}"
    digest=$(sha256 "${BUILD_DIR}/images/${name}" | awk '{print $1}')
    sep=","
    [ "$i" = "$last_idx" ] && sep=""
    cat <<EOF
    {
      "ref": "${src}",
      "file": "${name}",
      "sha256": "${digest}"
    }${sep}
EOF
  done
  echo '  ]'
  echo '}'
} > "${BUILD_DIR}/images/manifest.json"

jq . "${BUILD_DIR}/images/manifest.json" >/dev/null  # 校验 JSON 合法

# === 4. 拷入工具与文档 ===
echo
echo "==> [4/5] copy tools & docs"
cp "${SCRIPT_DIR}/mirror-images.sh"   "${BUILD_DIR}/tools/"
cp "${SCRIPT_DIR}/preflight-check.sh" "${BUILD_DIR}/tools/"
cp "${SCRIPT_DIR}/images.list"        "${BUILD_DIR}/tools/"
cp "${SCRIPT_DIR}/install.sh"         "${BUILD_DIR}/install.sh"
chmod +x "${BUILD_DIR}/tools/"*.sh "${BUILD_DIR}/install.sh"

# 可选：附带 README/example（不存在则跳过，不报错）
[ -f "${REPO_ROOT}/README-OFFLINE.md" ] && cp "${REPO_ROOT}/README-OFFLINE.md" "${BUILD_DIR}/"
[ -f "${REPO_ROOT}/values-bundle-example.yaml" ] && cp "${REPO_ROOT}/values-bundle-example.yaml" "${BUILD_DIR}/"

# === 5. SHA256SUMS + tar.gz ===
echo
echo "==> [5/5] SHA256SUMS + tar.gz"
( cd "${BUILD_DIR}" && find . -type f ! -name SHA256SUMS -print0 \
    | xargs -0 sha256 \
    | sed 's|  \./|  |' \
    | sort -k 2 \
    > SHA256SUMS )

( cd "${OUT_DIR}" && tar czf "${BUNDLE_NAME}.tar.gz" "${BUNDLE_NAME}" )

bundle_sha=$(sha256 "${TARBALL}" | awk '{print $1}')
bundle_size=$(du -sh "${TARBALL}" | awk '{print $1}')

echo
echo "=== DONE"
echo "    bundle  : ${TARBALL}"
echo "    size    : ${bundle_size}"
echo "    sha256  : ${bundle_sha}"
echo
echo "    解压后入口（二期 install.sh）："
echo "      tar xzf ${BUNDLE_NAME}.tar.gz && cd ${BUNDLE_NAME}"
echo "      DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot \\"
echo "        FROM_DIR=./images ./tools/mirror-images.sh   # 把镜像推到客户 registry"
echo "      ./tools/preflight-check.sh -n llm                # 集群预检"
echo "      helm install my-llm ./chart/llm-helm-deployer-${CHART_VERSION}.tgz \\"
echo "        --set global.imageRegistry=my-reg.io.example/llm \\"
echo "        --set 'global.imagePullSecrets[0].name=<your-pull-secret>'"
