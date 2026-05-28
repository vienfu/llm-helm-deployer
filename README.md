# llm-helm-deployer

一键部署 LLM（基于 vLLM、NVIDIA GPU、OpenAI 兼容 API）的 Helm Chart。

> Chart 位于 [`manifests/`](./manifests) 子目录。

## 前置依赖

- Kubernetes 集群
- 模型权重已经放在某台 GPU 节点的本地目录（首版仅支持 hostPath）

下面三个组件需要存在于集群中。**任选一种方式：**

| 组件 | 作用 | 已部署 → 直接复用 | 未部署 → 由本 chart 一并安装 |
|------|------|-------------------|------------------------------|
| NVIDIA device plugin | 让 K8s 能调度 `nvidia.com/gpu` | 默认（`nvidia-device-plugin.enabled=false`） | `--set nvidia-device-plugin.enabled=true` |
| dcgm-exporter | 暴露 GPU 显存等硬件指标 | 默认（`dcgm-exporter.enabled=false`） | `--set dcgm-exporter.enabled=true` |
| Prometheus（单实例） | 抓取 vLLM Pod 指标（annotation-based） | 默认（`prometheus.enabled=false`） | `--set prometheus.enabled=true` |
| Grafana（轻量可视化） | 加载内置 vLLM dashboard，自动连 Prometheus | 默认（`grafana.enabled=false`） | `--set grafana.enabled=true` 或 `tools/install.sh --with-grafana` |

> 四段子 chart 的所有 values 均可在对应顶层段下透传，例如调小 prometheus 保留期：`--set prometheus.server.retention=3d`，或切 grafana service type：`--set grafana.service.type=NodePort`。
>
> **如何调子 chart：** 直接在 [`manifests/values.yaml`](./manifests/values.yaml) 同名段下加字段即可（已预置常用项：调度、scrape annotation、retention 等）。完整字段见各 upstream values.yaml：
> - [nvidia-device-plugin](https://github.com/NVIDIA/k8s-device-plugin/blob/main/deployments/helm/nvidia-device-plugin/values.yaml)
> - [dcgm-exporter](https://github.com/NVIDIA/dcgm-exporter/blob/main/deployment/values.yaml)
> - [prometheus](https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml)
> - [grafana](https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/values.yaml)（自 2026-01 上游迁至 `grafana-community/helm-charts`）

## 快速开始

先拉取依赖（首次或更换版本时执行）：

```bash
helm dependency update ./manifests
```

最小安装（假设客户集群已有上面三个组件）：

```bash
helm install my-llm ./manifests \
  --set model.name=/models/Qwen2.5-7B-Instruct \
  --set model.hostPath.path=/data/models \
  --set vllm.tensorParallelSize=1 \
  --set 'nodeSelector.kubernetes\.io/hostname=gpu-node-1'
```

全栈安装（裸集群，把三个依赖也一起装）：

> ⚠️ 启用 `nvidia-device-plugin.enabled=true` 时**必须**通过 `--namespace` 指定一个非 `default` 的命名空间（这是 nvidia-device-plugin 子 chart 自身的硬约束）。下面示例用 `-n llm --create-namespace`。

```bash
helm install my-llm ./manifests -n llm --create-namespace \
  --set model.name=/models/Qwen2.5-7B-Instruct \
  --set model.hostPath.path=/data/models \
  --set 'nodeSelector.kubernetes\.io/hostname=gpu-node-1' \
  --set nvidia-device-plugin.enabled=true \
  --set dcgm-exporter.enabled=true \
  --set prometheus.enabled=true \
  --set grafana.enabled=true        # 内置 grafana + 自动加载 vLLM dashboard
```

测试：

```bash
helm test my-llm
```

## 关键 values 字段

| 字段 | 默认 | 说明 |
|------|------|------|
| `image.repository` / `image.tag` | `vllm/vllm-openai` / `v0.6.3` | vLLM 镜像 |
| `model.name` | `/models/Qwen2.5-7B-Instruct` | 传给 vLLM 的 `--model` |
| `model.servedName` | "" | `--served-model-name`，默认用 `model.name` 的 basename |
| `model.hostPath.path` | `/data/models` | 宿主机权重目录 |
| `model.hostPath.mountPath` | `/models` | 容器内挂载点（只读） |
| `vllm.tensorParallelSize` | 1 | 同时决定 `nvidia.com/gpu` 数量 |
| `vllm.gpuMemoryUtilization` | 0.9 | |
| `vllm.maxModelLen` | "" | 留空使用模型默认 |
| `vllm.dtype` | auto | |
| `vllm.trustRemoteCode` | false | |
| `vllm.extraArgs` | [] | 兜底参数 |
| `auth.apiKey` | "" | 非空则启用 OpenAI 风格 Bearer 鉴权 |
| `service.type` | ClusterIP | |
| `ingress.enabled` | false | |
| `metrics.serviceMonitor.enabled` | true | 是否给 vLLM Pod 注入 `prometheus.io/scrape` annotation（字段名沿用旧称以保留向后兼容；不再渲染 ServiceMonitor） |
| `metrics.grafanaDashboard.enabled` | false | 是否渲染 vLLM dashboard ConfigMap（label `grafana_dashboard=1`）。**注意**：当 `grafana.enabled=true` 时本字段会被联动认为 true，无需显式开启 |
| `nodeSelector` / `tolerations` / `affinity` | {} / [] / {} | hostPath 模式下务必配置 nodeSelector |
| `schedulerName` | "" | Pod 调度器名称，留空走 K8s 默认调度器；可填 `volcano` / `kai-scheduler` 等 |
| `shm.sizeLimit` | 8Gi | `/dev/shm` 大小，TP 大模型需要 |
| `nvidia-device-plugin.enabled` | false | 是否安装 NVIDIA device plugin DaemonSet |
| `dcgm-exporter.enabled` | false | 是否安装 dcgm-exporter |
| `prometheus.enabled` | false | 是否安装单实例 Prometheus（基于 prometheus-community/prometheus，关闭 alertmanager/pushgateway/node-exporter/kube-state-metrics） |
| `grafana.enabled` | false | 是否安装内置 Grafana（基于 grafana-community/grafana 12.4.1，appVersion 13.0.1-security-01）；启用后 sidecar 自动加载 vLLM dashboard，datasource 默认指向 `prometheus-server.<ns>.svc:80` |
| `grafana.adminPassword` | `admin` | 默认 admin 密码；生产环境建议改用 `grafana.admin.existingSecret` 走 Secret 注入 |
| `grafana.service.type` | ClusterIP | 切换为 `NodePort` / `LoadBalancer` 可外部访问 |
| `global.imageRegistry` | "" | 离线/私有 registry 镜像前缀（详见下方「离线 / 私有 registry 部署」） |
| `global.imagePullSecrets` | [] | 全局 pull secrets，会与顶层 `imagePullSecrets` 合并 |

## 离线 / 私有 registry 部署

> 完全无公网出口、希望发一个物料包给客户的场景，请直接看 [README-OFFLINE.md](./README-OFFLINE.md)（方案 C：完整 bundle，含 chart + 镜像 tar + 一键 install.sh）。本节描述方案 B：仅做 registry 重写。

客户集群无法直接访问 dockerhub / nvcr.io / quay.io / registry.k8s.io 时，按下面的步骤把镜像同步到客户内网 registry，再用 `global.imageRegistry` 一次性切换：

### 1. 同步镜像

仓库内置 [`tools/mirror-images.sh`](./tools/mirror-images.sh)，包含主 chart + 三个可选子 chart 的全部镜像清单（与 Chart.lock 锁定的 AppVersion 对齐）：

```bash
# 仅查看将执行的命令（不实际拉/推）
DEST_REG=my-reg.io.example/llm DRY_RUN=1 ./tools/mirror-images.sh

# 自动检测 CLI（按可用性：skopeo > nerdctl > docker > podman）
DEST_REG=my-reg.io.example/llm ./tools/mirror-images.sh

# 显式指定（互斥，至多一个）
DEST_REG=my-reg.io.example/llm USE_SKOPEO=1  ./tools/mirror-images.sh   # 推荐：无 daemon 依赖
DEST_REG=my-reg.io.example/llm USE_NERDCTL=1 ./tools/mirror-images.sh   # containerd 节点常用
DEST_REG=my-reg.io.example/llm USE_PODMAN=1  ./tools/mirror-images.sh   # RHEL/Rocky 默认
DEST_REG=my-reg.io.example/llm USE_DOCKER=1  ./tools/mirror-images.sh

# nerdctl 模式可注入 containerd namespace（让 kubelet 直接消费）
DEST_REG=my-reg.io.example/llm USE_NERDCTL=1 NERDCTL_NAMESPACE=k8s.io \
  ./tools/mirror-images.sh
```

镜像被搬运到 `${DEST_REG}/<image>:<tag>`，**目标仓库内统一扁平化（只保留镜像名:tag）**，不再保留源 registry 的多级目录。这样在 `--set sub.image.repository=...` 覆盖时只需要拼一次 `${DEST_REG}/<image>` 即可。

### 2. 离线安装

```bash
helm install my-llm ./manifests -n llm --create-namespace \
  --set global.imageRegistry=my-reg.io.example/llm \
  --set 'global.imagePullSecrets[0].name=my-pull-secret' \
  --set model.name=/models/Qwen2.5-7B-Instruct \
  --set model.hostPath.path=/data/models \
  --set 'nodeSelector.kubernetes\.io/hostname=gpu-node-1'
```

### 3. 子 chart 注意事项

| 子 chart | 是否接受 `global.imageRegistry` | 离线场景配置方式 |
|----------|------------------------------|-----------------|
| 主 chart（vLLM）| ✅ | 主 chart helper 自动拼前缀 |
| `prometheus` | ❌ | 需显式覆盖 `--set prometheus.server.image.repository=my-reg.io.example/llm/prometheus` 以及 `--set prometheus.server.configmapReload.prometheus.image.repository=my-reg.io.example/llm/prometheus-config-reloader` |
| `nvidia-device-plugin` | ❌ | 需显式覆盖 `--set nvidia-device-plugin.image.repository=my-reg.io.example/llm/k8s-device-plugin` |
| `dcgm-exporter` | ❌ | 需显式覆盖 `--set dcgm-exporter.image.repository=my-reg.io.example/llm/dcgm-exporter` |
| `grafana` | ❌ | 仅当 `grafana.enabled=true` 时需要：`--set grafana.image.repository=my-reg.io.example/llm/grafana` 以及 `--set grafana.sidecar.image.repository=my-reg.io.example/llm/k8s-sidecar` |

> `mirror-images.sh` 把镜像扁平化到 `${DEST_REG}/<image>:<tag>`，因此覆盖路径只需 `${DEST_REG}/<image>`，不再嵌套 `nvidia/k8s/...` 等多级目录。脚本结束时会打印对应的 `--set` 命令，可直接复制使用。

## 暴露的指标

vLLM 在 `:8000/metrics` 暴露：

- `vllm:time_to_first_token_seconds_*`（TTFT）
- `vllm:time_per_output_token_seconds_*`（TPOT）
- `vllm:request_success_total`、`vllm:num_requests_running`（吞吐 / 在飞）
- 等等

GPU 显存等硬件指标由集群侧 dcgm-exporter 提供，例如 `DCGM_FI_DEV_FB_USED`。

> **联动说明：** 当 `metrics.serviceMonitor.enabled=true`（默认）时，本 chart 会给 vLLM Pod 注入 `prometheus.io/scrape=true` / `prometheus.io/port=<vllm.port>` / `prometheus.io/path=/metrics` 三个 annotation。本仓库内置的单实例 Prometheus（`prometheus.enabled=true`）通过 `kubernetes_sd_configs` + `__meta_kubernetes_pod_annotation_*` 自动发现并抓取。如对接外部已有的 Prometheus / Prometheus Operator，可在外部配置同样的 annotation 抓取规则；也可关闭本字段后改用自定义 ServiceMonitor / PodMonitor。

## 已有 kube-prometheus-stack 用户升级路径

> 本 chart 在 v0.x 以前依赖 `kube-prometheus-stack`，自本次重构起改为 `prometheus`（单实例）。如你之前以 `--set kube-prometheus-stack.enabled=true` 安装过，请按以下步骤迁移：

```bash
# 1. 先 helm upgrade 到新版本（kube-prometheus-stack 子 chart 已被移除，原 release 中相应 workloads 会被一起卸载）
helm upgrade my-llm ./manifests -n llm \
  --set prometheus.enabled=true   # 如需保留监控

# 2. 手动清理 kube-prometheus-stack 留下的 CRD（Helm v3 默认不删 CRD）
kubectl delete crd \
  alertmanagerconfigs.monitoring.coreos.com \
  alertmanagers.monitoring.coreos.com \
  podmonitors.monitoring.coreos.com \
  probes.monitoring.coreos.com \
  prometheuses.monitoring.coreos.com \
  prometheusrules.monitoring.coreos.com \
  servicemonitors.monitoring.coreos.com \
  thanosrulers.monitoring.coreos.com
```

> 如继续需要 Operator 风格（ServiceMonitor / PodMonitor / Alertmanager），请独立安装 kube-prometheus-stack（不再由本 chart 托管），并在外部配置同样的 annotation 抓取或 PodMonitor 规则。
>
> 如仅需 Grafana 可视化（不要 Operator / Alertmanager），可直接 `--set grafana.enabled=true` 启用本 chart 内置的轻量 Grafana sub-chart，会自动加载 vLLM dashboard 并连上本 chart 的 Prometheus，不再依赖 KPS。

## 已知限制（首版）

- 仅 NVIDIA GPU + 文本模型
- 仅 hostPath 加载权重
- 单副本（无 HPA、无 PD 分离、无多模型路由）
