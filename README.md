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
| kube-prometheus-stack（含 Prometheus Operator + CRDs） | 识别 `ServiceMonitor` 并采集指标 | 默认（`kube-prometheus-stack.enabled=false`） | `--set kube-prometheus-stack.enabled=true` |

> 三段子 chart 的所有 values 均可在对应顶层段下透传，例如关闭 grafana：`--set kube-prometheus-stack.grafana.enabled=false`。
>
> **如何调子 chart：** 直接在 [`manifests/values.yaml`](./manifests/values.yaml) 同名段下加字段即可（已预置常用项：调度、ServiceMonitor、retention 等）。完整字段见各 upstream values.yaml：
> - [nvidia-device-plugin](https://github.com/NVIDIA/k8s-device-plugin/blob/main/deployments/helm/nvidia-device-plugin/values.yaml)
> - [dcgm-exporter](https://github.com/NVIDIA/dcgm-exporter/blob/main/deployment/values.yaml)
> - [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml)

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
  --set kube-prometheus-stack.enabled=true
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
| `metrics.serviceMonitor.enabled` | true | |
| `metrics.grafanaDashboard.enabled` | false | |
| `nodeSelector` / `tolerations` / `affinity` | {} / [] / {} | hostPath 模式下务必配置 nodeSelector |
| `schedulerName` | "" | Pod 调度器名称，留空走 K8s 默认调度器；可填 `volcano` / `kai-scheduler` 等 |
| `shm.sizeLimit` | 8Gi | `/dev/shm` 大小，TP 大模型需要 |
| `nvidia-device-plugin.enabled` | false | 是否安装 NVIDIA device plugin DaemonSet |
| `dcgm-exporter.enabled` | false | 是否安装 dcgm-exporter |
| `kube-prometheus-stack.enabled` | false | 是否安装 Prometheus Operator + CRDs（含 Grafana/Alertmanager） |
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

# 用 docker（默认）
DEST_REG=my-reg.io.example/llm ./tools/mirror-images.sh

# 用 skopeo（推荐，无需本地 docker daemon）
DEST_REG=my-reg.io.example/llm USE_SKOPEO=1 ./tools/mirror-images.sh
```

镜像被搬运到 `${DEST_REG}/<原 path>:<原 tag>`，路径与 tag 与公网保持一致，便于 `global.imageRegistry` 单点改写。

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
| `kube-prometheus-stack` | ✅ | upstream 原生支持，主 chart `global` 段会自动下发到子 chart |
| `nvidia-device-plugin` | ❌ | 需显式覆盖 `--set nvidia-device-plugin.image.repository=my-reg.io.example/llm/nvidia/k8s-device-plugin` |
| `dcgm-exporter` | ❌ | 需显式覆盖 `--set dcgm-exporter.image.repository=my-reg.io.example/llm/nvidia/k8s/dcgm-exporter` |

> 镜像同步脚本结束时会打印对应的 `--set` 命令，可直接复制使用。

## 暴露的指标

vLLM 在 `:8000/metrics` 暴露：

- `vllm:time_to_first_token_seconds_*`（TTFT）
- `vllm:time_per_output_token_seconds_*`（TPOT）
- `vllm:request_success_total`、`vllm:num_requests_running`（吞吐 / 在飞）
- 等等

GPU 显存等硬件指标由集群侧 dcgm-exporter 提供，例如 `DCGM_FI_DEV_FB_USED`。

> **联动说明：** 当 `kube-prometheus-stack.enabled=true` 时，本 chart 自动给 ServiceMonitor 注入 `release: <release-name>` 标签（kube-prometheus-stack 默认按此筛选 ServiceMonitor）。如果用对接外部已有的 Prometheus Operator，可通过 `metrics.serviceMonitor.labels.release=<your-prom-release>` 覆盖。

## 已知限制（首版）

- 仅 NVIDIA GPU + 文本模型
- 仅 hostPath 加载权重
- 单副本（无 HPA、无 PD 分离、无多模型路由）
