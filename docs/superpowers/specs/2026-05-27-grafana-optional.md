# 轻量 Grafana 可选 sub-chart 设计

- 日期：2026-05-27
- 作者：vienfu
- 状态：草案，待 review
- 关联文件：
  - [Chart.yaml](../../../manifests/Chart.yaml)
  - [values.yaml](../../../manifests/values.yaml)
  - [tools/images.list](../../../tools/images.list)
  - [tests/helm-static-test.sh](../../../tests/helm-static-test.sh)
  - [README.md](../../../README.md) / [README-OFFLINE.md](../../../README-OFFLINE.md)
- 前置 spec：[2026-05-26-monitoring-simplify.md](./2026-05-26-monitoring-simplify.md) §N1（Grafana 后议）

## 1. 背景与动机

当前监控栈瘦身后，本 chart 只内置单实例 Prometheus + 一份 dashboard JSON 投递（[grafana-dashboard.yaml](../../../manifests/templates/grafana-dashboard.yaml)，由 `metrics.grafanaDashboard.enabled` 控制，默认关闭）。客户场景分两类：

| 场景 | 当前能力 | 痛点 |
|---|---|---|
| 集群已有 Grafana（含 sidecar.dashboards） | 开 `metrics.grafanaDashboard.enabled=true` 即可被自动采集 | ✅ 已支持 |
| 集群已有 Grafana 但未启用 dashboard sidecar | 手动 import vllm-overview.json | 体验不一致 |
| **集群完全没有 Grafana** | **不支持，本 chart 不部署 Grafana** | 客户必须自带或额外引一套 KPS 重资产 |

第三类是当前设计缺口。本 spec 引入"轻量级、可选、默认关闭"的 Grafana sub-chart，**与 Prometheus 同级、互不强依赖**，让"开箱即看图"成为最少配置可达的能力，同时不破坏既有"瘦身"原则。

## 2. 目标与非目标

### 2.1 目标 (Goals)

- G1：以**官方 grafana/grafana** chart 作为 dependency（非 KPS 子集），默认 `enabled: false`，不引入额外 CRD。
- G2：默认开启 **dashboard sidecar**（kiwigrid/k8s-sidecar），自动发现本 chart 已投递的 ConfigMap（label `grafana_dashboard=1`）。
- G3：默认配置 **Prometheus datasource** 指向本 chart 的 prometheus-server Service，无需用户手填 URL。
- G4：默认 admin 密码通过 Secret 注入（支持外部已存 Secret 引用），不在 values 中明文。
- G5：可选启用 **persistence**（默认关闭，使用 emptyDir，符合"轻量"原则；客户可一键切换 PVC）。
- G6：默认 **Service: ClusterIP**，提供 Ingress 与 NodePort 两种暴露开关（默认全关）。
- G7：完全离线可达：所有镜像（含 sidecar、init、bash 工具镜像）登记到 [tools/images.list](../../../tools/images.list)；未在镜像列表的隐藏镜像被静态测试守门。
- G8：与 monitoring-simplify 的 ServiceMonitor-free 决策一致：本 sub-chart 不引入 Operator/CR 依赖。

### 2.2 非目标 (Non-Goals)

- N1：不引入 Loki / Tempo / Mimir 等可观测性扩展。
- N2：不引入 Grafana Operator / Grafana Cloud 集成。
- N3：不接管已有 Grafana 实例的配置（如客户已有 Grafana，仍走 sidecar 自动发现路径，本 sub-chart 保持默认关闭）。
- N4：不实现 SSO/LDAP 等高级身份方案（保留为开放配置项，由客户在 `grafana.grafana.ini` 自定义）。

## 3. 用户故事

- **US-1**：客户 A 全新集群，无任何监控组件。希望执行 `helm install ... --set prometheus.enabled=true --set grafana.enabled=true` 即可在浏览器看到 vLLM 仪表盘。
- **US-2**：客户 B 已有 KPS Grafana。希望本 chart 默认不安装 Grafana，仅投递 dashboard ConfigMap。
- **US-3**：客户 C 离线/气隙环境（场景 C）。希望 build-bundle 后的 tar 包**自带** Grafana 镜像，且 install.sh 一键完成镜像同步与部署。
- **US-4**：客户 D 严格安全要求。希望 admin 密码读自外部已存的 Secret（如 ESO 拉下来的），values 中**不存在**明文。

## 4. 设计概览

### 4.1 架构关系

```
parent chart (llm-vllm)
├── prometheus  (sub-chart, optional, default disabled)
│       └── prometheus-server Service  ← 被 grafana datasource 引用
├── grafana     (sub-chart, optional, default disabled)   ★ 本 spec 新增
│       ├── grafana Deployment + Service
│       └── k8s-sidecar (默认开启)：扫 namespace 中 label=grafana_dashboard=1 的 ConfigMap
└── templates/grafana-dashboard.yaml  (label 已就绪，被 sidecar 自动加载)
```

关键流：parent chart 的 dashboard ConfigMap → sidecar 发现 → Grafana 加载，无需手动 import。

### 4.2 选用上游 chart

- 上游：`grafana/grafana`（官方维护，独立于 KPS）
- 仓库：`https://grafana.github.io/helm-charts`
- 锁定版本：以提交本 spec 时上游 stable 为准（建议 `~9.0.0`，appVersion 11.x）；具体版本号在实施 PR 中冻结，记录到 [Chart.yaml](../../../manifests/Chart.yaml) 与 [Chart.lock](../../../manifests/Chart.lock)。
- 拒绝：`kube-prometheus-stack` 内嵌 Grafana（与 monitoring-simplify 决策冲突，会重新引入 Operator/CRD）。

### 4.3 Chart.yaml 增量

```yaml
dependencies:
  - name: prometheus
    version: 29.8.0
    repository: https://prometheus-community.github.io/helm-charts
    condition: prometheus.enabled
  - name: grafana                       # ★ 新增
    version: ~9.0.0                     # 实施 PR 中冻结具体小版本
    repository: https://grafana.github.io/helm-charts
    condition: grafana.enabled
```

### 4.4 values.yaml 增量（关键字段）

```yaml
grafana:
  enabled: false                        # G1：默认关闭

  grafana:                              # 子 chart 命名空间
    image:
      repository: grafana/grafana       # 注：上游不识别 global.imageRegistry
      # tag: 留空时随 chart appVersion；离线场景由 install.sh --image-registry 重写

    # 默认 admin 凭据：使用外部已存 Secret 优先
    admin:
      existingSecret: ""                # 若非空：使用该 Secret 的 admin-user/admin-password
      userKey: admin-user
      passwordKey: admin-password
    # 若 existingSecret 为空，且未显式 set adminPassword，子 chart 会自动生成随机密码

    persistence:
      enabled: false                    # G5：默认 emptyDir
      # 启用时：
      # enabled: true
      # size: 10Gi
      # storageClassName: ""

    service:
      type: ClusterIP                   # G6
      port: 80

    ingress:
      enabled: false                    # G6
      ingressClassName: ""
      hosts: []
      tls: []

    sidecar:                            # G2：dashboard sidecar
      dashboards:
        enabled: true
        label: grafana_dashboard
        labelValue: "1"
        searchNamespace: ALL            # 兼容 dashboard 与 Grafana 不在同 ns 的场景
        folder: /tmp/dashboards
        provider:
          allowUiUpdates: false
      datasources:
        enabled: false                  # 我们用 datasources 字段直接渲染，不走 sidecar 扫描

    # G3：默认 datasource 指向本 chart 部署的 prometheus
    # {{ .Release.Name }}-prometheus-server 是 prometheus sub-chart 在本 chart 内的 Service 名
    datasources:
      datasources.yaml:
        apiVersion: 1
        datasources:
          - name: Prometheus
            type: prometheus
            access: proxy
            isDefault: true
            url: http://{{ .Release.Name }}-prometheus-server.{{ .Release.Namespace }}.svc:80
            editable: false

    # 资源默认（轻量）
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

> 注：`grafana.grafana.*` 双层是因为 parent values 顶层 key `grafana` 即 sub-chart 命名空间，再加一层 `grafana:`（非必需，仅当上游 values 内部还有同名 key 时；此处保留示意，实施时按上游真实 schema 落地）。

### 4.5 与现有 dashboard 投递的协同

- [manifests/templates/grafana-dashboard.yaml](../../../manifests/templates/grafana-dashboard.yaml) 已使用 label `grafana_dashboard: "1"`，与本 sub-chart 默认 sidecar `label/labelValue` 完全一致。
- 当 `grafana.enabled=true` 而 `metrics.grafanaDashboard.enabled=false` 时：sidecar 不会扫到任何东西，Grafana 启动正常但仪表盘空白。
- 推荐组合：实施 PR 中**联动两个开关**——`grafana.enabled=true` 隐式开启 `metrics.grafanaDashboard.enabled=true`（除非用户显式关闭）。
  - 实现方式：在 `grafana-dashboard.yaml` 渲染条件加 `or`：`{{- if or .Values.metrics.grafanaDashboard.enabled .Values.grafana.enabled }}`

## 5. 离线/气隙支持（场景 C）

### 5.1 [tools/images.list](../../../tools/images.list) 增补

```
# Grafana (optional, controlled by grafana.enabled)
docker.io/grafana/grafana:<frozen-tag>
quay.io/kiwigrid/k8s-sidecar:<frozen-tag>
docker.io/library/busybox:<frozen-tag>            # init container
```

- 以上 tag 在实施 PR 中通过 `helm template` 渲染默认 values 提取后冻结。
- [tests/helm-static-test.sh#L150](../../../tests/helm-static-test.sh#L150) 当前把 `grafana` 作为禁止关键字，需要按本 spec 实施时改成"允许 grafana 镜像，但仍禁止意外的 KPS 关键字（如 `kube-prometheus-stack`、`prometheus-operator`、`alertmanager`）"。

### 5.2 镜像 registry 重写

- 上游 `grafana/grafana` chart **不识别 `global.imageRegistry`**，需要按现有 sub-chart 注释约定，在 values 注释中提供"私有仓覆盖示例"（与 prometheus 注释段同款）。
- install.sh 的 `--image-registry` 参数仍然只透传给 mirror-images.sh；用户需要在 helm install 时显式 `--set grafana.grafana.image.repository=my-reg.io/llm/grafana`。

### 5.3 测试

- 在 [tests/bundle-smoke-test.sh](../../../tests/bundle-smoke-test.sh) 增加：
  - 用例：`grafana.enabled=true` + `--use-docker` 时，dry-run 输出包含 `grafana/grafana` 与 `kiwigrid/k8s-sidecar` 的 `pull/tag/push` 三连
  - 用例：`grafana.enabled=false`（默认）时，输出**不**包含 grafana 镜像
- 在 [tests/helm-static-test.sh](../../../tests/helm-static-test.sh) 增加：
  - `helm template ... --set grafana.enabled=true` 渲染成功
  - 渲染产物包含 `kind: Deployment` 且 `metadata.name=*-grafana`
  - datasource ConfigMap 的 url 字段指向 `*-prometheus-server.*svc`

## 6. 实施计划（拆分 commit）

按"小步快跑、每步可独立 review"原则：

| Commit | 内容 | 预期变更面 |
|---|---|---|
| C1 `feat(grafana): add optional grafana sub-chart` | Chart.yaml + Chart.lock + values.yaml 增加 grafana 段（默认 false） | 3 个文件 |
| C2 `feat(dashboard): auto-render when grafana.enabled` | grafana-dashboard.yaml 渲染条件改 `or` | 1 个文件 |
| C3 `chore(images): add grafana image set to images.list` | images.list 增补 + helm-static-test 守门规则放宽（保留 KPS 关键字禁止） | 2 个文件 |
| C4 `test(grafana): bundle + static smoke cases` | smoke + static 测试用例 | 2 个文件 |
| C5 `docs(grafana): README & README-OFFLINE` | 用户开关说明 + 离线步骤 + 客户场景三选一指南 | 2 个文件 |

每个 commit 独立可回滚；C1-C2 是必要核心，C3-C5 是离线/质量加固。

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| grafana chart 版本未冻结导致离线 bundle 漂移 | 镜像 tag 不一致 → mirror 失败 | 实施 PR 中 `~9.0.0` → 冻结到具体 patch 版本，记录 Chart.lock |
| 上游 chart 修改默认 sidecar label key | 现有 dashboard ConfigMap 失效 | values.yaml 显式 `sidecar.dashboards.label/labelValue`，覆盖上游默认 |
| Datasource URL 在不同 release name 下错误 | Grafana 起来了但抓不到指标 | 用 `{{ .Release.Name }}-prometheus-server` 模板化，并在 helm-static-test 渲染断言 |
| 客户已开 KPS，又开本 sub-chart 导致双 Grafana | 资源冲突，dashboard 重复 | README 显式建议互斥；values 注释提示 |
| admin 密码默认随机不可预期 | 客户首次登录困难 | values 注释展示 "kubectl get secret ... -o jsonpath=..." 取密一行命令 |
| 镜像列表/守门规则联动 | 漏改导致 CI 失败 | 把 helm-static-test 的"禁止关键字"清单从 `grafana` 改为 `kube-prometheus-stack`/`prometheus-operator`/`alertmanager`/`thanos` |

## 8. 兼容性

- **向后兼容**：默认 `grafana.enabled=false`，已有客户升级无任何行为变化。
- **values key 命名**：顶层 `grafana` 与上游 sub-chart name 一致；内部字段透传，未来上游升级仅需调 Chart.yaml 版本号 + 跑 `helm dependency update`。
- **CRD**：零新增 CRD，与 monitoring-simplify §核心约束一致。
- **helm 版本要求**：保持 prometheus chart 已要求的 Helm 3.7+；grafana 9.x 同样满足。

## 9. 验收标准 (Acceptance Criteria)

1. `helm install ... --set grafana.enabled=true` 在新集群上成功部署 Grafana Pod，且 `kubectl port-forward svc/<release>-grafana 3000:80` 可访问登录页。
2. 默认 admin 密码可通过 `kubectl get secret <release>-grafana -o jsonpath='{.data.admin-password}' | base64 -d` 取到。
3. Grafana 内默认 datasource = Prometheus，URL = `http://<release>-prometheus-server.<ns>.svc:80`，状态 "Working"。
4. vLLM 仪表盘自动出现在 Grafana 首页（无需手动 import）。
5. `grafana.enabled=false`（默认）时，`helm template` 输出不包含任何 Grafana 资源。
6. `tests/bundle-smoke-test.sh` 与 `tests/helm-static-test.sh` 全绿。
7. 离线 bundle (`build-bundle.sh` + `install.sh --use-docker --image-registry my-reg.io/llm`) 在断网环境完成 mirror + install。
8. 与已有 KPS 共存场景：`grafana.enabled=false` 时与历史行为完全一致。

## 10. 开放问题 / Review 待定

- Q1：是否在 C2 联动 dashboard 渲染条件？或保持两个开关独立、用 README 引导用户同时开启？（推荐联动，理由：默认行为更符合直觉）
- Q2：Ingress 的 host 是否给一个默认占位（`grafana.example.local`）？或保持空让用户必填？（推荐保持空，避免误用）
- Q3：是否在 install.sh 增加 `--with-grafana` 顶层 alias，避免用户手敲 `--set grafana.enabled=true`？（轻便，可放 C5 文档同步阶段）
- Q4：grafana chart 具体冻结版本（`9.x.y` 中的 `y`）由实施 PR 决定，是否在本 spec 留空？（推荐留空，由 PR 时点的最新 patch 决定，避免 spec 与实施脱钩）
