# llm-helm-deployer 设计文档

- 日期: 2026-05-18
- 仓库: `github.com/vienfu/llm-helm-deployer`
- 作者: brainstorming session
- 状态: 待用户最终审阅

## 1. 项目定位

提供一个**一键部署 LLM 推理服务**的 Helm Chart：

- 推理引擎：开源 [vLLM](https://github.com/vllm-project/vllm)（官方镜像 `vllm/vllm-openai`）
- 模型范围：**仅文本模型**
- 硬件范围：**仅 NVIDIA GPU**
- 对外协议：**OpenAI 兼容 HTTP API**（vLLM 内置）
- 可观测性：暴露常见服务指标（GPU 显存、TTFT、TPOT、吞吐等），通过 Prometheus 拉取

非目标（首版明确不做）：

- 多模型路由、PD（Prefill/Decode）分离
- HPA / 弹性扩缩
- AMD ROCm、CPU 推理、多模态
- 模型权重的远端拉取（HF Hub / S3 / NFS / CSI PVC）—— 仅在后续版本扩展

## 2. MVP 范围

**单 chart 一次安装 = 一个模型 + 一个副本**。

- `replicas` 固定为 1
- 副本扩缩、多模型部署通过「多次 `helm install` 不同 release」解决
- `Deployment.strategy.type = Recreate`（单副本 + GPU 紧缺，避免滚动死锁）

## 3. 架构总览

```
┌──────────────────────────────────────────────────────────┐
│  K8s 集群                                                 │
│                                                          │
│   ┌──────────────────────────────────────────┐           │
│   │  Pod (vllm/vllm-openai)                  │           │
│   │  - args 来自 values.vllm.* + extraArgs    │           │
│   │  - /models  ← hostPath (RO)               │           │
│   │  - /dev/shm ← emptyDir{Memory}            │           │
│   │  - resources.limits.nvidia.com/gpu = TP   │           │
│   │  - /v1/* (OpenAI API)  /metrics (Prom)    │           │
│   └──────────────────────────────────────────┘           │
│         ▲                          ▲                     │
│         │ ClusterIP Service        │ ServiceMonitor      │
│         │ (+ 可选 Ingress)         │ (Prom Operator)     │
│         │                          │                     │
│   外部调用方 (OpenAI SDK)      集群侧 Prometheus            │
│                                + dcgm-exporter (集群已装) │
└──────────────────────────────────────────────────────────┘
```

依赖前置（chart 不内置）：

- 集群已安装 **NVIDIA device plugin**（`nvidia.com/gpu` 资源可调度）
- 集群已部署 **dcgm-exporter** DaemonSet（GPU 显存等硬件指标的来源）
- 集群已部署 **Prometheus Operator**（`ServiceMonitor` CRD 可识别）

## 4. 模型加载策略

首版 **仅支持 hostPath**：

- 用户在 `values.model.hostPath.path` 指向宿主机权重目录
- 容器以 `readOnly` 挂载到 `values.model.hostPath.mountPath`（默认 `/models`）
- `values.model.name` 传给 vLLM `--model`，可以是路径（如 `/models/Qwen2.5-7B-Instruct`）
- 由于是 hostPath，**Pod 必须落到放有权重的节点**，强烈建议配 `nodeSelector` 锁节点
- `HF_HUB_OFFLINE=1` 默认设置，禁止容器联网拉取

未来扩展：NFS、CSI-based PVC、S3/OBS init-container 预拉。本次设计不实现，但 values 命名应能向后兼容（`model.source.type` 留作未来字段，首版隐式 `hostPath`）。

## 5. values.yaml 抽象

```yaml
image:
  repository: vllm/vllm-openai
  tag: v0.6.3
  pullPolicy: IfNotPresent
imagePullSecrets: []

model:
  name: /models/Qwen2.5-7B-Instruct
  servedName: ""
  hostPath:
    path: /data/models
    type: Directory
    mountPath: /models

vllm:
  tensorParallelSize: 1
  gpuMemoryUtilization: 0.9
  maxModelLen: ""
  dtype: auto
  trustRemoteCode: false
  port: 8000
  extraArgs: []

auth:
  apiKey: ""

service:
  type: ClusterIP
  port: 8000
  annotations: {}

ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: llm.example.com
      paths:
        - path: /
          pathType: Prefix
  tls: []

resources:
  limits:
    nvidia.com/gpu: 1   # 模板会自动用 vllm.tensorParallelSize 覆盖
  requests: {}
nodeSelector: {}
tolerations: []
affinity: {}

probes:
  startup:
    enabled: true
    failureThreshold: 60
    periodSeconds: 10
    httpGet: { path: /health, port: 8000 }
  readiness:
    enabled: true
    httpGet: { path: /health, port: 8000 }
    periodSeconds: 10
  liveness:
    enabled: true
    httpGet: { path: /health, port: 8000 }
    periodSeconds: 30

metrics:
  serviceMonitor:
    enabled: true
    interval: 15s
    labels: {}
    relabelings: []
  grafanaDashboard:
    enabled: false

podAnnotations: {}
podLabels: {}
podSecurityContext: {}
securityContext: {}
terminationGracePeriodSeconds: 60

shm:
  sizeLimit: 8Gi
```

抽象决策：

- **vLLM 启动参数：高阶字段 + extraArgs**。常用项白名单显式暴露，其他用 `extraArgs` 兜底。
- **GPU 数量自动同步**：模板把 `resources.limits."nvidia.com/gpu"` 强制 = `vllm.tensorParallelSize`，用户 values 中即便填错也会被覆盖；保证「填一个数即可」。
- **shm 默认 8Gi**：vLLM 多进程使用 `/dev/shm`，TP 大模型需要更大共享内存，以默认 emptyDir{medium: Memory} 提供。

## 6. 模板文件结构

```
llm-helm-deployer/
├── Chart.yaml
├── values.yaml
├── README.md
├── .helmignore
├── templates/
│   ├── _helpers.tpl
│   ├── NOTES.txt
│   ├── serviceaccount.yaml
│   ├── secret-apikey.yaml          # if .Values.auth.apiKey
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml                # if .Values.ingress.enabled
│   ├── servicemonitor.yaml         # if .Values.metrics.serviceMonitor.enabled
│   ├── grafana-dashboard.yaml      # if .Values.metrics.grafanaDashboard.enabled
│   └── tests/
│       └── test-connection.yaml    # helm test
├── dashboards/
│   └── vllm-overview.json
└── ci/
    ├── default-values.yaml
    ├── ingress-values.yaml
    ├── auth-values.yaml
    └── tp2-values.yaml
```

不包含 `values.schema.json`（用户决定先不加）。

## 7. 关键模板逻辑

集中在 `_helpers.tpl`：

1. `llm-helm-deployer.vllmArgs`
   - 起手：`--model {{ .Values.model.name }}`
   - 自动追加 `--served-model-name <servedModelName>`（见下）
   - 把 `vllm.tensorParallelSize` / `gpuMemoryUtilization` / `maxModelLen` / `dtype` / `trustRemoteCode` 渲染为对应 CLI flag（空值跳过）
   - `auth.apiKey` 非空 → 追加 `--api-key $(VLLM_API_KEY)`（值由 env 注入，避免出现在 ps）
   - 末尾 append `vllm.extraArgs`

2. `llm-helm-deployer.gpuCount` = `vllm.tensorParallelSize | int`

3. `llm-helm-deployer.servedModelName` = 若 `model.servedName` 非空则用之；否则取 `model.name` 的 basename

4. 标准 `name`/`fullname`/`labels`/`selectorLabels` 模板（含 `app.kubernetes.io/*`）

`deployment.yaml` 关键骨架：

- `replicas: 1`，`strategy.type: Recreate`
- `volumes`: `model-store` (hostPath) + `dshm` (emptyDir Memory)
- `containers[0]`:
  - `image` / `args`（来自 `vllmArgs`）
  - `env`: `HF_HUB_OFFLINE=1` + 可选 `VLLM_API_KEY`
  - `ports`: `http=8000`
  - `volumeMounts`: `/models` (RO) + `/dev/shm`
  - `resources.limits."nvidia.com/gpu"` = `gpuCount`
  - 三探针均 `httpGet /health :8000`，参数来自 `values.probes.*`
- `nodeSelector` / `tolerations` / `affinity` 完整透传
- `terminationGracePeriodSeconds` 默认 60s

`service.yaml`: ClusterIP，端口 `http=8000`，便于 ServiceMonitor 通过端口名抓取。

`servicemonitor.yaml`: `endpoints: [{port: http, path: /metrics, interval}]`，labels/relabelings 透传。

`secret-apikey.yaml`: `auth.apiKey` 非空时创建，键名 `api-key`，base64 编码。

`ingress.yaml`: 标准 networking.k8s.io/v1，按 `hosts/paths/tls` 渲染。

`tests/test-connection.yaml`: 一次性 Pod，curl `/v1/models` 校验 200，作为 `helm test` 入口。

`NOTES.txt`: 安装后给出三段 curl 示例（list models / chat / completion）。

## 8. 指标与监控

- vLLM 内置指标在 `:8000/metrics`，含 `vllm:time_to_first_token_seconds`、`vllm:time_per_output_token_seconds`、`vllm:request_success_total`、`vllm:num_requests_running` 等（覆盖 TTFT、TPOT、吞吐）。
- 显存等 GPU 硬件指标由集群 dcgm-exporter 提供，与 chart 解耦。
- `metrics.serviceMonitor.enabled` 默认 `true`，下发 `ServiceMonitor`，让集群 Prometheus Operator 自动拉取。
- `metrics.grafanaDashboard.enabled` 默认 `false`；开启时通过 ConfigMap + label `grafana_dashboard: "1"` 让 Grafana sidecar 自动挂载（Dashboard 文件在 `dashboards/vllm-overview.json`）。

## 9. 测试策略

**静态校验（CI 可跑，无需 GPU）**

- `helm lint` 对每个 `ci/*-values.yaml` 跑一遍
- `helm template` + `kubeconform` 校验生成 manifest 合法
- 用 `helm template` 输出 + `yq` 断言：
  - `tensorParallelSize=2` ⇒ `nvidia.com/gpu=2` 且 `--tensor-parallel-size 2`
  - `auth.apiKey` 非空 ⇒ Secret + env + `--api-key` 三处都出现；为空 ⇒ 三处都不出现
  - `ingress.enabled` 与 `metrics.serviceMonitor.enabled` 切换正确
  - hostPath 的 `path` / `mountPath` 正确传递

**运行时验证（手动，需要 GPU 集群）**

- `helm install` 默认 values
- `helm test` 执行 `tests/test-connection.yaml`，curl `/v1/models` 拿 200
- 手动用 OpenAI Python SDK 跑 `chat.completions.create`
- 确认 Prometheus 抓到 vLLM 指标 + dcgm-exporter 显存指标
- **不**做 kind/minikube 的自动化（kind 没 GPU，覆盖不到核心路径）

## 10. 安全 / 健壮性约束

- Secret 不打 log；apiKey 通过 env 注入而非命令行明文
- 容器默认 `readOnly` 挂载模型卷
- `HF_HUB_OFFLINE=1` 防止意外联网
- `terminationGracePeriodSeconds=60` 给 vllm 排空在飞请求
- 探针超时给足，避免大模型加载期被 liveness 误杀（startupProbe `failureThreshold=60 * periodSeconds=10s` ≈ 10 分钟启动预算）

## 11. 后续迭代方向（不在本次 scope）

- 模型来源扩展：NFS / CSI PVC / S3-init-container
- HPA（基于 vLLM `num_requests_waiting` 或 GPU 利用率）
- 多副本（需要权重共享存储到位后才有意义）
- 鉴权方案升级（JWT / 外部 OIDC）
- 多模型路由（独立 router chart 或 chart-of-charts）
- PD 分离部署形态
