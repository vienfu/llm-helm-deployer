# Prometheus Web 认证（Basic Auth）可选化 设计

- 日期：2026-06-11
- 作者：vienfu
- 状态：草案，待 review
- 关联文件：
  - [Chart.yaml](../../../manifests/Chart.yaml)
  - [values.yaml](../../../manifests/values.yaml)
  - [templates/_helpers.tpl](../../../manifests/templates/_helpers.tpl)
  - [templates/grafana-dashboard.yaml](../../../manifests/templates/grafana-dashboard.yaml)
  - [ci/auth-values.yaml](../../../manifests/ci/auth-values.yaml)
  - [README.md](../../../README.md)
- 前置 spec：[2026-05-27-grafana-optional.md](./2026-05-27-grafana-optional.md)（Grafana datasource 默认指向 prometheus-server）

## 1. 背景与动机

当前 chart 内置的单实例 Prometheus（prometheus-community/prometheus 29.8.0，appVersion v3.11.3）默认裸暴露 `:9090` Web UI 与 `/api/v1/*`，依赖网络隔离作为唯一防线。生产场景中常需要：

- 通过 Ingress / NodePort 暴露 Prometheus 时，避免任何人匿名访问指标与查询接口；
- 保留 Grafana 作为面向用户的图形入口，但 Prometheus 接口仍要做最小化身份校验；
- 满足合规要求（"管理端不得匿名访问"）。

Prometheus 自 2.24+ 原生支持 `--web.config.file` 配置 HTTP Basic Auth，但接入需要：bcrypt 哈希、卷挂载、子 chart 字段穿透、探针适配、Grafana datasource 联动。这些步骤分散且容易踩坑，因此本 spec 把"开启 Basic Auth"沉淀为一个可选开关，并在开启时自动处理上下游联动。

## 2. 目标与非目标

### 2.1 目标 (Goals)

- G1：在 [values.yaml](../../../manifests/values.yaml) 提供单一开关 `prometheus.server.webAuth.enabled`，默认 `false`，零行为变化。
- G2：开启时支持两种凭据来源：
  - **内联模式**：用户写 `username/password`（明文），chart 自动 bcrypt 哈希为 Secret；
  - **外部 Secret 模式**：用户提供 `existingSecret`，chart 直接挂载，不接触明文。
- G3：Secret 内容幂等：相同明文密码在多次 `helm upgrade` 下不应触发 Secret 重写与 Pod 重启。
- G4：自动适配 prometheus-server 探针，避免 401 误杀（首选 TCP 探针，回退 `probeHeaders` 注入 Authorization）。
- G5：Grafana datasource 自动联动：开启 auth 时通过环境变量 + secureJsonData 注入凭据，Grafana 内不留明文。
- G6：保持向后兼容：用户已通过 `prometheus.server.extraArgs` / `extraVolumes` 自定义的字段不被覆盖（采用 merge）。
- G7：CI / 静态测试覆盖（auth on/off 两种渲染均通过 `helm lint` 与 `helm template`）。

### 2.2 非目标 (Non-Goals)

- N1：不实现 mTLS / TLS 终止（由 Ingress 层负责，超出 Prometheus 自身配置范围）。
- N2：不实现 OAuth2 / SSO 接入（建议走 oauth2-proxy + Ingress，正交方案）。
- N3：不引入 cert-manager / 外部密钥管理（KMS、Vault），仅做 Kubernetes Secret 内的 bcrypt。
- N4：不为 Grafana 自身加 Basic Auth；Grafana 自带 admin 登录已足够。
- N5：不重写 prometheus-community 子 chart 的探针逻辑，仅在外层透传配置。

## 3. Values 接口设计

新增字段（仅展示新增部分，注释将合入实际 [values.yaml](../../../manifests/values.yaml)）：

```yaml
prometheus:
  server:
    # ---- Web 认证（Basic Auth）----
    # 开启后，Prometheus :9090 所有 HTTP 端点都会要求 Basic Auth。
    # Grafana datasource 在 grafana.enabled=true 时会自动同步凭据，
    # liveness/readiness 探针会自动改为 TCP，避免 401 误杀。
    webAuth:
      enabled: false              # 总开关，默认关
      username: admin             # 用户名（仅 enabled=true 时生效）
      password: ""                # 明文密码；留空时 chart 生成 24 位随机
      existingSecret: ""          # 进阶：使用外部 Secret，需含 web.yml + password 两个 key
```

字段语义：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `enabled` | bool | `false` | 总开关；`false` 时整个特性零行为变化 |
| `username` | string | `admin` | Basic Auth 用户名 |
| `password` | string | `""` | 明文密码；为空且未设 `existingSecret` 时由 chart 生成 |
| `existingSecret` | string | `""` | 已存在 Secret 名称；非空时跳过 chart 内置 Secret 创建 |

校验规则：
- `enabled=true` 且 `existingSecret=""`：生成 chart 管理的 Secret；
- `enabled=true` 且 `existingSecret!=""`：跳过 Secret 渲染，直接挂载用户提供的 Secret；
- `existingSecret` 必须含两个 key：`web.yml`（prometheus 用）、`password`（grafana env 用）；缺失 `password` 时 NOTES.txt 给出警告并禁用 Grafana auth 联动。

## 4. 模板新增与改动

### 4.1 新增 templates/prometheus-web-auth-secret.yaml

仅当 `prometheus.server.webAuth.enabled=true` 且 `existingSecret==""` 时渲染。

核心要点：

1. **bcrypt 哈希**：使用 sprig `htpasswd "<user>" "<pass>"` 生成 `user:hash` 字符串，截取 hash 部分写入 `web.yml`。
2. **幂等性**：通过 `lookup "v1" "Secret" .Release.Namespace <name>` 探测同名 Secret；命中时复用其 `web.yml` 中已有 hash，避免每次 `helm upgrade` 因 bcrypt salt 不同导致 Secret 漂移与 Pod 重启。仅当 `password` 真正变化时才重新哈希。
3. **password 明文 key**：同时把明文密码写入 `password` key，供 grafana datasource 通过 `envFromSecret` 注入。
4. **Secret 命名**：`<release>-prometheus-web-auth`，由 [_helpers.tpl](../../../manifests/templates/_helpers.tpl) 提供 helper。

伪代码：

```yaml
{{- if and .Values.prometheus.server.webAuth.enabled (eq .Values.prometheus.server.webAuth.existingSecret "") }}
{{- $name := printf "%s-prometheus-web-auth" .Release.Name -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- $user := .Values.prometheus.server.webAuth.username -}}
{{- $pass := .Values.prometheus.server.webAuth.password | default (randAlphaNum 24) -}}
{{- $hash := "" -}}
{{- if $existing }}
  {{/* 复用已有 hash，避免重新加盐 */}}
  {{- $hash = index $existing.data "passwordHash" | b64dec -}}
  {{- $pass = index $existing.data "password" | b64dec -}}
{{- else }}
  {{- $hash = htpasswd $user $pass | trimPrefix (printf "%s:" $user) -}}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
type: Opaque
stringData:
  web.yml: |
    basic_auth_users:
      {{ $user }}: {{ $hash }}
  password: {{ $pass | quote }}
  passwordHash: {{ $hash | quote }}
{{- end }}
```

> 注：`htpasswd` 是 sprig 0.3+ 提供的函数，Helm 3 内置可用。

### 4.2 改 values：默认 overlay 注入 prometheus 子 chart

主 chart 不直接修改子 chart values 文件；而是在 [values.yaml](../../../manifests/values.yaml) 默认值里追加一段"开启 webAuth 时的 overlay"。但 Helm 不支持"条件 values"，故采用以下方式之一（实施时确认）：

- **方式 A（推荐）**：在 [values.yaml](../../../manifests/values.yaml) 的 `prometheus.server` 下静态追加 `extraArgs / extraVolumes / extraVolumeMounts` 的占位与说明，**用户开启 enabled 即生效**；占位采用 helm 模板友好的形式，由子 chart 直接消费。

  即：将 webAuth 字段改造为子 chart 可消费的 `extraArgs / extraVolumes / extraVolumeMounts` 与之等价，并在主 chart 顶层 values 中通过 helm `tpl` + `lookup` 自动渲染对应 K8s 资源（参见 4.1 的 Secret）。挂载本身依赖子 chart 字段，故仍需用户/或本 chart 在 default values 中带上下面的"开启块"。

- **方式 B（备选）**：在 [values.yaml](../../../manifests/values.yaml) 的 `prometheus.server.extraArgs` / `extraVolumes` / `extraVolumeMounts` 默认就声明，但用 `{{- if }}` 条件包裹的 helm 表达式（仅在父 chart 是 helm 渲染时才有效；事实上 Helm 在 dependencies values 合并阶段不支持模板）。**Helm 不允许 values 文件内含模板表达式**，方式 B 不可行。

故实施采用 **方式 A 的变体**：把这些 overlay 写在主 chart 的 `templates/_helpers.tpl` 中，通过 helm `chart-level` 的 `Values.prometheus` mutable 处理。Helm 实际机制是：父 chart values.yaml 中 `prometheus:` 段会作为子 chart 的 values，且**支持静态字段**。我们的折中方案是：

1. 主 chart [values.yaml](../../../manifests/values.yaml) 的 `prometheus.server` 下默认提供 `extraArgs / extraVolumes / extraVolumeMounts`，**始终开启** `web.config.file` 与卷挂载，但 Secret 内容在 `webAuth.enabled=false` 时是一个"空 web.yml"（不含 `basic_auth_users`）；此时 prometheus 启动加载 web.yml 但无认证生效，等价于关闭。
2. Secret 模板在 `enabled=false` 时仍渲染为"空文件 + 空 password"，保证子 chart 卷挂载有源；用户感受不到任何变化。
3. `enabled=true` 时 Secret 内容切换为带 `basic_auth_users:`，prometheus 通过 `web.config.file` 热加载（v3.11.3 已支持）即可生效。

> 此设计避免了 helm "条件 values" 的根本限制，同时让 enable/disable 切换无需重启 Pod、无需重新 `helm upgrade` 主 chart 的子 chart values。

### 4.3 探针适配

prometheus-community/prometheus 29.8.0 子 chart 默认探针为 HTTP `/-/healthy` / `/-/ready`。开启 auth 后这些路径要求认证，会导致 401 失败。

实施顺序（以子 chart 实际暴露字段为准）：

1. **首选：改 TCP 探针**。子 chart `server.probeScheme: HTTPS|HTTP`，但不直接支持改协议为 TCP。验证后若不支持，进入回退。
2. **回退：HTTP 探针 + Authorization header**。利用 K8s 1.21+ httpGet 的 `httpHeaders` 字段，注入 `Authorization: Basic <base64>`。

   - 由于子 chart 通常未暴露 `probeHeaders` 字段，需要通过 `server.podAnnotations` 或 patch 方式注入；最干净的做法是利用子 chart 提供的 `server.extraInitContainers` / `server.sidecarContainers` 是不行的（它们改不到主容器 probe）。
   - **若子 chart 不支持 probe 自定义**，回退至本 chart 提供的 `kustomize-style` post-render（不引入），或在 NOTES.txt 提示用户额外执行 `kubectl patch deployment prometheus-server` —— 这是 best-effort 兜底，仅在两条路径都失败时使用。
3. **再回退：放弃探针严格性**。在 NOTES.txt 提示用户当前 Prometheus 探针失效，但容器进程崩溃 K8s 仍会重启，functional 影响有限。

实施阶段第一步即跑通 1 或 2，避免落到 3。

### 4.4 Grafana datasource 联动

修改 [values.yaml](../../../manifests/values.yaml) `grafana` 段的 datasource 默认配置（参见现有 [values.yaml#L356-L367](../../../manifests/values.yaml#L356-L367)）：

```yaml
grafana:
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus-server.{{ .Release.Namespace }}.svc:80
          isDefault: true
          {{- if .Values.prometheus.server.webAuth.enabled }}
          basicAuth: true
          basicAuthUser: {{ .Values.prometheus.server.webAuth.username }}
          secureJsonData:
            basicAuthPassword: ${PROM_BASIC_PASS}
          {{- end }}
```

> Helm values 文件不允许模板，故这段不能直接放在 [values.yaml](../../../manifests/values.yaml)。实施方式：把整个 datasource 渲染逻辑移到 chart 自身的 grafana sidecar ConfigMap 模板中（已在 [grafana-dashboard.yaml](../../../manifests/templates/grafana-dashboard.yaml) 同目录下，改为 sub-chart 透传或由我们自管 datasource），或利用 helm `--set-file` / `--post-renderer`。

实际方案：

1. 关闭 grafana sub-chart 自带的默认 datasource（`grafana.sidecar.datasources.enabled=true`）；
2. 由本 chart 新增 `templates/grafana-datasource.yaml`，渲染 `ConfigMap` 带 `grafana_datasource: "1"` label，sidecar 自动加载。模板可访问全部 helm 上下文，按 `webAuth.enabled` 条件渲染 `basicAuth` 字段。
3. 通过 `grafana.envFromSecret: <release>-prometheus-web-auth-env`（或直接 `grafana.extraSecretMounts`）把 Secret 中 `password` 注入为 `PROM_BASIC_PASS` 环境变量；datasource ConfigMap 用 `${PROM_BASIC_PASS}` 引用，运行时由 grafana 替换。

这样：
- 用户 values 中**永远不出现明文**；
- enable/disable 切换只改 datasource ConfigMap 与 grafana env，sidecar 检测变化自动 reload；
- Grafana 不需要重启。

### 4.5 helm test 增强

[templates/tests/test-connection.yaml](../../../manifests/templates/tests/test-connection.yaml) 新增 Prometheus 端点验证：

- `webAuth.enabled=false`：`curl -fsS http://prometheus-server:80/-/ready` 期望 200。
- `webAuth.enabled=true`：
  - 无凭据访问期望 401；
  - 用 Secret 中凭据访问期望 200。

测试容器从 Secret `password` key 读密码，避免明文写入 PodSpec。

## 5. CI / 静态测试

新增 [ci/auth-on-values.yaml](../../../manifests/ci/auth-on-values.yaml)：

```yaml
prometheus:
  server:
    webAuth:
      enabled: true
      username: admin
      password: testpass-do-not-use-in-prod
grafana:
  enabled: true
```

`helm lint` + `helm template -f ci/auth-on-values.yaml` 必须通过：

- 渲染出 `prometheus-web-auth` Secret（含 `web.yml` 包含 `basic_auth_users`）；
- 渲染出 grafana datasource ConfigMap（含 `basicAuth: true`）；
- 渲染出 grafana env 注入。

`tests/helm-static-test.sh`（如存在）增加上述两条断言。

## 6. 文档更新

- [README.md](../../../README.md) 监控章节新增 "Prometheus Web 认证（可选）" 小节，给出三步上手 + 关闭/外部 Secret 两种用法。
- [README-OFFLINE.md](../../../README-OFFLINE.md)：无新增镜像，无需调整（`htpasswd` 由 helm 内置 sprig 提供）。

## 7. 风险与回退

| 风险 | 缓解 |
|---|---|
| 子 chart 不支持探针自定义 → 401 杀 Pod | 4.3 节三级回退，最差降级为 NOTES 提示 |
| `htpasswd` sprig 函数兼容性 | 已在 Helm 3.x 通用支持，CI 验证 |
| 用户已自定义 `extraArgs` / `extraVolumes` 被覆盖 | 用 `merge` 而非 `replace`；模板检测同名字段并 fail-fast 提示 |
| 明文密码进入 Helm release secret | 不可避免（Helm 自身机制）；推荐用户使用 `existingSecret` 模式 |
| `lookup` 在 `helm template`（dry-run）下返回空 → 每次 dry-run hash 不同 | 仅影响 `--dry-run`；真实 install/upgrade 走 lookup 复用，不影响幂等性 |

## 8. 验收清单

- [ ] `webAuth.enabled=false`（默认）下 `helm template` 与 `helm install` 行为与现状完全一致。
- [ ] `webAuth.enabled=true` 内联模式：访问 `:9090/-/ready` 401，带 Basic 凭据 200。
- [ ] `webAuth.enabled=true` 内联模式：连续两次 `helm upgrade` 后 prometheus-server Pod 不被重启（Secret 幂等）。
- [ ] `webAuth.enabled=true` + `grafana.enabled=true`：Grafana 内 Prometheus datasource Test 通过，所有 dashboard 数据正常。
- [ ] `webAuth.enabled=true` 切换为 `false` 后，401 端点恢复为 200，Grafana datasource 自动去掉 basicAuth。
- [ ] `existingSecret` 模式：用户自管 Secret，chart 不创建额外 Secret，Grafana 联动按 `password` key 是否存在自动启停。
- [ ] CI：`auth-on-values.yaml` lint + template 通过。
- [ ] helm test：on/off 两种模式均通过。
