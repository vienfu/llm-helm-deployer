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
| `shm.sizeLimit` | 8Gi | `/dev/shm` 大小，TP 大模型需要 |
| `nvidia-device-plugin.enabled` | false | 是否安装 NVIDIA device plugin DaemonSet |
| `dcgm-exporter.enabled` | false | 是否安装 dcgm-exporter |
| `kube-prometheus-stack.enabled` | false | 是否安装 Prometheus Operator + CRDs（含 Grafana/Alertmanager） |

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
