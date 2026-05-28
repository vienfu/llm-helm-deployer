# 离线 / 私有化部署（方案 C：完整 bundle）

适用客户：**集群无公网出口**，且希望**单一物料包**包含全部 chart、子 chart、镜像与脚本。

> 如果客户集群可以从公网拉镜像或仅需 registry 重写，请直接看 [README.md 的「离线 / 私有 registry 部署」](./README.md) 一节（方案 B：仅 `global.imageRegistry`）。

## bundle 结构

```
llm-deployer-bundle-<ver>/
├── chart/llm-helm-deployer-<chart-version>.tgz   # helm package 输出，含子 chart tarball
├── images/
│   ├── manifest.json                             # ref → file → SHA256
│   └── *.tar                                     # skopeo docker-archive，amd64
├── tools/
│   ├── mirror-images.sh                          # FROM_DIR 模式可重复用于二次重推
│   ├── preflight-check.sh                        # 集群预检
│   └── images.list                               # 与 build-bundle.sh 共享的镜像清单
├── install.sh                                    # 一键入口
└── SHA256SUMS                                    # bundle 内全文件指纹
```

## 构建 bundle（厂商侧，有公网）

```bash
# 依赖：helm, skopeo, jq, tar, sha256sum/shasum
./tools/build-bundle.sh
# 输出： dist/llm-deployer-bundle-<chart-version>.tar.gz
```

可选参数：
- `--version <v>`：覆盖 bundle 版本号（默认取 `manifests/Chart.yaml` 的 `version`）
- `--out-dir <dir>`：指定输出目录（默认 `./dist`）

镜像清单见 [tools/images.list](./tools/images.list)，新增/删除镜像直接改文件即可，`build-bundle.sh` 与 `mirror-images.sh` 都会读这一份。

## 客户侧落地

### 0. 拷贝 + 解压

通过 U 盘 / 内网堡垒机把 `llm-deployer-bundle-<ver>.tar.gz` 上传到能连客户 registry **且能 `kubectl`** 的运维机：

```bash
tar xzf llm-deployer-bundle-<ver>.tar.gz
cd llm-deployer-bundle-<ver>
```

### 1. 一键安装

```bash
./install.sh \
  --dest-reg my-reg.io.example/llm \
  --dest-user ci-bot \
  --create-pull-secret \
  -n llm --release my-llm \
  --use-skopeo \
  --set model.name=/models/Qwen2.5-7B-Instruct \
  --set model.hostPath.path=/data/models
# 脚本会一次性提示「请输入镜像仓库密码」，密码绝不入 env / 命令行 / shell 历史
#
# 客户场景没装 skopeo / docker？install.sh 还支持：
#   --use-nerdctl   （containerd 节点常用，可配合 NERDCTL_NAMESPACE=k8s.io）
#   --use-podman
#   --use-docker
#   都不指定时，mirror-images.sh 会按 skopeo > nerdctl > docker > podman 自动选择
```

`install.sh` 编排步骤：

| # | 步骤 | 跳过开关 | 说明 |
|---|------|----------|------|
| 1 | SHA256SUMS 校验 | `--skip-sha` | 防止传输损坏 |
| 2 | 集群预检 | `--skip-preflight` | GPU 节点检测；如客户集群未装 ServiceMonitor CRD 可加 `--skip-sm` 跳过历史检查（本 chart 已不再依赖 ServiceMonitor，改为 annotation-based scrape） |
| 3 | 镜像同步 | `--skip-mirror` | `mirror-images.sh FROM_DIR=./images` |
| 4 | 创建 imagePullSecret | 默认关闭，`--create-pull-secret` 启用 | dockerconfigjson 类型 |
| 5 | `helm upgrade --install` | （无） | 自动注入 `global.imageRegistry` |

完整参数见 `./install.sh --help`。

### 2. 拆解流程（用于排障 / 自定义）

如不希望 `install.sh` 一键完成，可分别执行：

```bash
# 2.1 集群预检
./tools/preflight-check.sh -n llm

# 2.2 镜像同步（FROM_DIR 离线模式；任选其一 CLI）
FROM_DIR=./images USE_SKOPEO=1 \
DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot \
  ./tools/mirror-images.sh
# 或客户机只有 nerdctl：
#   FROM_DIR=./images USE_NERDCTL=1 NERDCTL_NAMESPACE=k8s.io \
#   DEST_REG=my-reg.io.example/llm DEST_USER=ci-bot ./tools/mirror-images.sh
# 提示输入密码

# 2.3 创建 pull secret（如需）
kubectl -n llm create secret docker-registry llm-pull-secret \
  --docker-server=my-reg.io.example \
  --docker-username=ci-bot --docker-password='<PASS>'

# 2.4 helm 安装
helm upgrade --install my-llm ./chart/llm-helm-deployer-*.tgz \
  -n llm --create-namespace \
  --set global.imageRegistry=my-reg.io.example/llm \
  --set 'global.imagePullSecrets[0].name=llm-pull-secret' \
  --set model.name=/models/Qwen2.5-7B-Instruct \
  --set model.hostPath.path=/data/models
```

## 约束与注意事项

- **架构**：`build-bundle.sh` 默认 `--override-arch amd64`，arm64 集群需自行重打。
- **不含模型权重**：模型仍走 `model.hostPath`，需另行将权重目录拷到 GPU 节点（详见主 [README.md](./README.md) 的「模型权重」一节）。
- **子 chart 镜像覆盖**：`nvidia-device-plugin` / `dcgm-exporter` / `prometheus` 均不识别 `global.imageRegistry`，需在 `install.sh` 后追加（**注意**：`mirror-images.sh` v2 起目标仓库内的镜像路径已扁平化，只保留 `<image>:<tag>`，不再嵌套 `nvidia/k8s/...` 等多级目录）：
  ```
  --set 'nvidia-device-plugin.image.repository=my-reg.io.example/llm/k8s-device-plugin' \
  --set 'dcgm-exporter.image.repository=my-reg.io.example/llm/dcgm-exporter' \
  --set 'prometheus.server.image.repository=my-reg.io.example/llm/prometheus' \
  --set 'prometheus.server.configmapReload.prometheus.image.repository=my-reg.io.example/llm/prometheus-config-reloader'
  ```
- **TLS 自签**：客户 registry 用自签证书时，`install.sh --dest-tls-verify false`（仅 skopeo 模式生效；docker / nerdctl / podman 模式需先在对应 daemon/containerd/registries.conf 配 `insecure-registries`）。
- **可重入**：`install.sh` 全程基于 `helm upgrade --install` 与 `kubectl apply`，可重复执行；镜像同步阶段也可单独重跑（`tools/mirror-images.sh` + `FROM_DIR=./images`）。

## 退出码语义

| code | 来源 | 含义 |
|------|------|------|
| 0    | install / mirror / preflight | 全部通过 |
| 1    | install / preflight | preflight FAIL（阻塞）/ install 中 helm 失败 |
| 2    | install / mirror | 参数错误 / 缺必填 / 路径不存在 |
| 3    | 任意 | 缺工具（helm/kubectl/skopeo/jq...） |
| 4    | install / mirror | 密码为空 |
| 5    | install / mirror | SHA256SUMS 损坏 / FROM_DIR archive 缺失 |

## 烟囱测试（CI）

`tests/bundle-smoke-test.sh` 用伪 bundle + DRY_RUN 验证三件套契约（参数解析、退出码、命令拼接、安全约束），不依赖真实 K8s / skopeo / docker daemon：

```bash
./tests/bundle-smoke-test.sh
# 期望: PASS=37 FAIL=0
```
