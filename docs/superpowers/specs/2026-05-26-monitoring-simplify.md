# 监控栈瘦身设计：kube-prometheus-stack -> prometheus 单实例

- 日期：2026-05-26
- 作者：vienfu
- 状态：草案，待 review
- 关联文件：[Chart.yaml](../../../manifests/Chart.yaml)、[values.yaml](../../../manifests/values.yaml)、[servicemonitor.yaml](../../../manifests/templates/servicemonitor.yaml)

## 1. 背景与动机

当前 `manifests/Chart.yaml` 依赖 `kube-prometheus-stack 65.0.0`，离线 bundle 至少要同步 5 个监控镜像；若按上一轮 review 升级到 `85.3.3`，镜像数会涨到 8~10 个，并引入 10 个 CRD、Operator + admission webhook 整套生命周期管理。

对本项目主要诉求 —— **抓取 vLLM Pod 暴露的 OpenAI metrics + 配套展示** —— 来说，KPS 的 alertmanager / grafana / kube-state-metrics / node-exporter / Operator/CRD 都属于"附带能力"，不是必需品。本设计将监控依赖瘦身为单实例 Prometheus，去除 CRD 依赖，最大化降低离线运维负担。

## 2. 目标与非目标

### 2.1 目标
- **G1**：把监控依赖从 KPS 替换为 `prometheus-community/prometheus` 单实例。
- **G2**：移除对 `monitoring.coreos.com` CRD 的依赖（删除 ServiceMonitor 模板，改用 annotation-based scrape）。
- **G3**：离线监控镜像清单缩减到 1 个（`quay.io/prometheus/prometheus`）。
- **G4**：默认存储使用 `emptyDir`，提供 PVC 切换开关，保持 PoC/简单场景"开箱即用"。
- **G5**：保持现有 `metrics.serviceMonitor.enabled` 行为兼容性 —— 用户只是从配置 ServiceMonitor 变成配置 Pod annotation，能力等价。

### 2.2 非目标
- **N1**：本次不引入 Grafana 部署（用户选择"Grafana 后议"）。
- **N2**：不做监控历史数据迁移；升级路径定义为"卸载旧 KPS → 安装新版 chart"。
- **N3**：不引入 Alertmanager / 告警规则，本期项目无告警需求。
- **N4**：不为 KPS 提供平滑迁移工具；用户若已基于 KPS 二次开发，需自行评估。

## 3. 架构变更

### 3.1 依赖图

**变更前**
```
llm-helm-deployer
├── nvidia-device-plugin  (条件)
├── dcgm-exporter         (条件)
└── kube-prometheus-stack (条件) -> 7 个子 chart + 10 CRD + Operator
```

**变更后**
```
llm-helm-deployer
├── nvidia-device-plugin  (条件)
├── dcgm-exporter         (条件)
└── prometheus            (条件) -> 单 Pod prometheus-server
```

### 3.2 抓取方式

**变更前（ServiceMonitor）**
- `manifests/templates/servicemonitor.yaml` 渲染一个 `monitoring.coreos.com/v1 ServiceMonitor`。
- 依赖 KPS Operator watch ServiceMonitor 并写到 Prometheus 配置。

**变更后（annotation-based scrape）**
- vLLM Pod 上添加 `prometheus.io/scrape`、`prometheus.io/port`、`prometheus.io/path` 三个 annotation。
- Prometheus 通过 `kubernetes_sd_configs role: pod` + relabel 自动发现并抓取。
- ServiceMonitor 模板删除。

### 3.3 数据流

```
vLLM Pod (:8000/metrics)
    │  (annotation: prometheus.io/scrape=true)
    ▼
prometheus-server  (kubernetes_sd_configs role:pod, ClusterRole:watch pods)
    │  (默认 emptyDir，重启数据丢失；可切 PVC)
    ▼
外接 Grafana / kubectl port-forward 9090 (后议)
```

## 4. 详细设计

### 4.1 Chart 依赖变更

[Chart.yaml](../../../manifests/Chart.yaml) 移除 `kube-prometheus-stack`，新增：

```yaml
- name: prometheus
  version: "25.27.0"   # 实际锁定值在 helm dep update 时确定
  repository: https://prometheus-community.github.io/helm-charts
  condition: prometheus.enabled
```

执行 `helm dependency update manifests` 重新生成 `Chart.lock`。

### 4.2 values.yaml 变更

#### 4.2.1 metrics 段（顶层）
- 字段名保持向后兼容性命名：保留 `metrics.serviceMonitor.enabled` 不动，主 chart 模板侧改为渲染 annotation 而不是 ServiceMonitor 对象。
  - 理由：`serviceMonitor` 是用户语义中"是否被 Prometheus 抓取"，命名虽不严谨，但保留可避免外部使用方破坏。文档中明确说明字段含义。
- 备选：把字段重命名为 `metrics.scrape.enabled`，提供过渡期 alias。**本设计选保留旧字段名 + 文档澄清**，YAGNI。

#### 4.2.2 删除 `kube-prometheus-stack:` 整段
[values.yaml:L160-L186](../../../manifests/values.yaml#L160-L186) 整段删除。

#### 4.2.3 新增 `prometheus:` 段

```yaml
prometheus:
  enabled: false                # 默认关闭，与现有 KPS 默认行为一致
  alertmanager:
    enabled: false
  prometheus-pushgateway:
    enabled: false
  prometheus-node-exporter:
    enabled: false
  kube-state-metrics:
    enabled: false
  server:
    image:
      repository: quay.io/prometheus/prometheus
      tag: v3.11.3              # 与 images.list 锁定一致
    persistentVolume:
      enabled: false            # 默认 emptyDir；切 PVC 时设为 true
      size: 20Gi
      storageClass: ""
    retention: "7d"
    resources:
      requests: { cpu: 100m, memory: 512Mi }
      limits:   { cpu: "1",  memory: 2Gi }
    extraScrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
```

### 4.3 模板变更

#### 4.3.1 删除 `templates/servicemonitor.yaml`
直接物理删除，不保留任何 `# removed` 注释（按项目约定）。

#### 4.3.2 修改 `templates/deployment.yaml`
在 Pod template metadata 的 `annotations:` 块下追加：

```yaml
{{- if .Values.metrics.serviceMonitor.enabled }}
prometheus.io/scrape: "true"
prometheus.io/port: {{ .Values.service.port | quote }}
prometheus.io/path: "/metrics"
{{- end }}
```

字段说明：
- `port` 沿用 `.Values.service.port`，因为 vLLM container port 与 Service port 一致（OpenAI 兼容服务的常规设定）。
- `path` 固定为 `/metrics`（vLLM 默认）。

### 4.4 离线 bundle 变更

#### 4.4.1 [tools/images.list](../../../tools/images.list)

**删除**（KPS 65.0.0 段，5 行）：
```text
quay.io/prometheus/prometheus:v2.54.1
quay.io/prometheus-operator/prometheus-operator:v0.77.1
docker.io/grafana/grafana:11.2.x
registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
quay.io/prometheus/node-exporter:v1.8.2
```

**新增**（1 行）：
```text
quay.io/prometheus/prometheus:v3.11.3
```

#### 4.4.2 其他工具脚本
- `tools/build-bundle.sh`：无改动，images.list 是 source of truth。
- `tools/mirror-images.sh`：无改动。
- `tools/preflight-check.sh`：移除"ServiceMonitor CRD"预检（如有），改为可选项 `--require-prometheus-scrape`（本次不引入，YAGNI）。
- `tools/install.sh`：无改动。

### 4.5 文档变更
- [README.md](../../../README.md)：监控章节用一段话说明"内置可选 Prometheus 单实例，使用 annotation-based scrape，不再依赖 ServiceMonitor CRD"。
- [README-OFFLINE.md](../../../README-OFFLINE.md)：镜像清单段同步。

## 5. 兼容性与升级路径

### 5.1 全新部署
直接安装新版 chart 即可，无 KPS 残留问题。

### 5.2 已有基于 KPS 的部署
**升级路径**（写入 README）：
1. `helm uninstall <release>` 卸载旧 chart（注意：StatefulSet PVC 不会自动删除）。
2. `kubectl delete crd alertmanagerconfigs.monitoring.coreos.com alertmanagers.monitoring.coreos.com podmonitors.monitoring.coreos.com probes.monitoring.coreos.com prometheusagents.monitoring.coreos.com prometheuses.monitoring.coreos.com prometheusrules.monitoring.coreos.com scrapeconfigs.monitoring.coreos.com servicemonitors.monitoring.coreos.com thanosrulers.monitoring.coreos.com`（如确认不再需要）。
3. 安装新版 chart。
4. 旧监控历史数据若需保留，需在 step 1 之前手动备份（`promtool tsdb dump` / 快照）。

### 5.3 现有 ServiceMonitor 配置
- 用户如果在 [values.yaml:L157-L158](../../../manifests/values.yaml#L157-L158) 设了 `metrics.serviceMonitor.enabled: true`，无需改配置，新模板会自动改渲染 annotation。
- 用户如果用了 `metrics.serviceMonitor.labels/interval/scrapeTimeout` 等高级字段：本设计**不再支持**，文档中明确列出 deprecation 列表。

## 6. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 用户原本依赖 KPS Grafana / dashboard | 升级后 Grafana 缺失 | README 升级章节明确告知 Grafana 后续单独提供（本期 N1） |
| annotation-based scrape 跨 namespace 要 ClusterRole | RBAC 不足时抓不到 Pod | `prometheus-community/prometheus` 默认创建 ClusterRole，无需额外配置 |
| `extraScrapeConfigs` 是用户可覆盖字段 | 用户传自己的配置时会整体替换默认 | 文档提示：要保留默认抓取规则的用户应"复制后追加"而不是"完全替换" |
| `service.port` 字段缺失或与 metrics 端口不一致 | annotation 端口错误 | 在 `_helpers.tpl` 加 `validate` 或在 NOTES.txt 提示用户校验；本次保持现状，下一版加 helper 校验 |
| 旧版用户卸载流程未清 CRD 残留 | namespace 被卡住 | README 里给出确切的 `kubectl delete crd` 命令（5.2 节） |

## 7. 测试与验收

### 7.1 静态校验
- `helm dependency update manifests`
- `helm lint manifests`
- `helm template manifests --set prometheus.enabled=true | kubeconform -strict -summary`
- `helm template manifests --set prometheus.enabled=true,metrics.serviceMonitor.enabled=true` 渲染应包含 `prometheus.io/scrape: "true"` annotation，且不包含 `kind: ServiceMonitor`

### 7.2 离线 bundle smoke test
- `tests/bundle-smoke-test.sh` 新增用例：
  - 镜像清单只含 1 个监控镜像（`grep prometheus tools/images.list | wc -l == 1`）
  - dry-run install 应不再 reference KPS 任何子 chart

### 7.3 端到端验证（本地集群）
- 安装 chart 并 `prometheus.enabled=true`
- 启动 vLLM Pod
- `kubectl port-forward svc/llm-prometheus-server 9090:80`
- 访问 `http://localhost:9090/api/v1/targets`，应能看到 vLLM Pod target 处于 `UP` 状态
- 查询 `vllm:num_requests_running` 等 vLLM metrics 应返回数据

## 8. 实施分解

预期拆成 4 个独立任务，按顺序提交：

1. **chore(deps)**: 替换 Chart.yaml 依赖、更新 Chart.lock、更新 images.list
2. **feat(monitor)**: 删除 servicemonitor.yaml、deployment.yaml 加 annotation、values.yaml 改 prometheus 段
3. **test(monitor)**: 更新 bundle-smoke-test.sh，新增渲染断言
4. **docs(monitor)**: README + README-OFFLINE 同步

## 9. 待确认事项

- [ ] Grafana 方案（独立 spec，下个迭代讨论）
- [ ] 是否需要在 chart 内自带最小化告警规则（PrometheusRule 已不可用，需要换成 prometheus server 的 `extraConfigmapMounts`）—— 默认 N3，不实施
