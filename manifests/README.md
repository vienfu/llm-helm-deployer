# llm-helm-deployer

一键部署 LLM（基于 vLLM、NVIDIA GPU、OpenAI 兼容 API）的 Helm Chart。

## 前置依赖

- Kubernetes 集群
- 已安装 NVIDIA device plugin（节点上能调度 `nvidia.com/gpu`）
- 已部署 dcgm-exporter DaemonSet（提供 GPU 显存等硬件指标）
- 已部署 Prometheus Operator（识别 `ServiceMonitor` CRD）
- 模型权重已经放在某台 GPU 节点的本地目录（首版仅支持 hostPath）

## 快速开始

```bash
helm install my-llm . \
  --set model.name=/models/Qwen2.5-7B-Instruct \
  --set model.hostPath.path=/data/models \
  --set vllm.tensorParallelSize=1 \
  --set 'nodeSelector.kubernetes\.io/hostname=gpu-node-1'
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

## 暴露的指标

vLLM 在 `:8000/metrics` 暴露：

- `vllm:time_to_first_token_seconds_*`（TTFT）
- `vllm:time_per_output_token_seconds_*`（TPOT）
- `vllm:request_success_total`、`vllm:num_requests_running`（吞吐 / 在飞）
- 等等

GPU 显存等硬件指标由集群侧 dcgm-exporter 提供，例如 `DCGM_FI_DEV_FB_USED`。

## 已知限制（首版）

- 仅 NVIDIA GPU + 文本模型
- 仅 hostPath 加载权重
- 单副本（无 HPA、无 PD 分离、无多模型路由）
