# Prometheus Web 认证（Basic Auth）可选化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Prometheus HTTP Basic Auth 沉淀为单开关可选特性，开启时自动联动 Grafana 数据源、探针与 helm test，关闭时零行为变化。

**Architecture:** `prometheus.server.webAuth.enabled` 单开关；模板始终渲染一个 Secret 与 prometheus 的 `--web.config.file` 挂载，关闭态时 Secret 内 web.yml 不含 `basic_auth_users`（Prometheus 视作无认证）。开启态时通过 sprig `htpasswd` 生成 bcrypt 哈希，并通过 `lookup` 复用既有 Secret 的 hash 保证幂等。Grafana 联动通过自管 datasource ConfigMap + envFromSecret 注入密码。

**Tech Stack:** Helm 3 (sprig), Prometheus v3.11.3 web config, Grafana sidecar discovery, prometheus-community/prometheus 29.8.0 子 chart `extraArgs / extraVolumes / extraVolumeMounts`。

**Spec:** [docs/superpowers/specs/2026-06-11-prometheus-web-auth-design.md](../specs/2026-06-11-prometheus-web-auth-design.md)

---

## 文件结构总览

| 操作 | 路径 | 责任 |
|---|---|---|
| 新增 | `manifests/templates/prometheus-web-auth-secret.yaml` | 始终渲染 Secret，包含 `web.yml` / `password` / `passwordHash` 三个 key |
| 新增 | `manifests/templates/grafana-datasource.yaml` | 自管 Grafana Prometheus datasource ConfigMap，按 webAuth.enabled 条件加 basicAuth |
| 新增 | `manifests/ci/auth-on-values.yaml` | CI 用例：webAuth + grafana 全开 |
| 修改 | `manifests/values.yaml` | 新增 `prometheus.server.webAuth` 段；prometheus.server 默认带上 extraArgs/extraVolumes/extraVolumeMounts；grafana 段加 envFromSecret + 关 sub-chart 自带 datasource |
| 修改 | `manifests/templates/_helpers.tpl` | 新增 `webAuthSecretName`、`webAuthEnabled` 两个 helper |
| 修改 | `manifests/templates/tests/test-connection.yaml` | 新增 prometheus 401 / 200 验证（仅 prometheus.enabled=true 且 webAuth 开启时） |
| 修改 | `tests/helm-static-test.sh` | 新增 [7/7] 用例：auth on/off 渲染断言 |
| 修改 | `README.md` | 监控章节追加"Prometheus Web 认证（可选）"小节 |

---

## Task 1: 新增 helper 与 Secret 模板（关闭态）

目标：让"关闭态"下也能渲染出空内容 Secret，以便后续 prometheus 子 chart 静态挂载。

**Files:**
- Modify: `manifests/templates/_helpers.tpl` (追加到末尾)
- Create: `manifests/templates/prometheus-web-auth-secret.yaml`

- [ ] **Step 1: 添加 helpers**

在 [_helpers.tpl](../../manifests/templates/_helpers.tpl) 末尾追加：

```gotemplate
{{/*
Prometheus Web Auth Secret 名称：始终为 <release>-prometheus-web-auth
*/}}
{{- define "llm-helm-deployer.webAuthSecretName" -}}
{{- printf "%s-prometheus-web-auth" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Prometheus Web Auth 是否启用（值为 "true"/"false" 字符串，便于模板比较）
*/}}
{{- define "llm-helm-deployer.webAuthEnabled" -}}
{{- if and (hasKey .Values "prometheus") (hasKey .Values.prometheus "server") (hasKey .Values.prometheus.server "webAuth") -}}
{{- if .Values.prometheus.server.webAuth.enabled -}}true{{- else -}}false{{- end -}}
{{- else -}}false{{- end -}}
{{- end -}}
```

- [ ] **Step 2: 创建 Secret 模板（仅 prometheus 子 chart 启用时渲染）**

写入 [prometheus-web-auth-secret.yaml](../../manifests/templates/prometheus-web-auth-secret.yaml)：

```gotemplate
{{- /*
始终渲染：开启态写入 basic_auth_users + 明文 password，关闭态写入空 web.yml；
通过 lookup 复用同名 Secret 中的 hash，保证 helm upgrade 幂等。
仅当 prometheus 子 chart 启用 (.Values.prometheus.enabled=true) 才渲染，
避免独立外部 Prometheus 场景下出现孤立 Secret。
用户提供 existingSecret 时跳过。
*/ -}}
{{- if and .Values.prometheus.enabled (eq (.Values.prometheus.server.webAuth.existingSecret | default "") "") -}}
{{- $name := include "llm-helm-deployer.webAuthSecretName" . -}}
{{- $enabled := eq (include "llm-helm-deployer.webAuthEnabled" .) "true" -}}
{{- $user := .Values.prometheus.server.webAuth.username | default "admin" -}}
{{- $pass := .Values.prometheus.server.webAuth.password | default "" -}}
{{- $hash := "" -}}
{{- if $enabled -}}
  {{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
  {{- if and $existing (hasKey $existing.data "passwordHash") -}}
    {{- $existingPass := index $existing.data "password" | b64dec -}}
    {{- if or (eq $pass "") (eq $pass $existingPass) -}}
      {{/* 密码未变化（或留空使用旧值）：复用旧 hash 与旧明文，保持幂等 */}}
      {{- $hash = index $existing.data "passwordHash" | b64dec -}}
      {{- $pass = $existingPass -}}
    {{- else -}}
      {{- $hash = htpasswd $user $pass | trimPrefix (printf "%s:" $user) -}}
    {{- end -}}
  {{- else -}}
    {{- if eq $pass "" -}}
      {{- $pass = randAlphaNum 24 -}}
    {{- end -}}
    {{- $hash = htpasswd $user $pass | trimPrefix (printf "%s:" $user) -}}
  {{- end -}}
{{- end -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
type: Opaque
stringData:
  web.yml: |-
{{- if $enabled }}
    basic_auth_users:
      {{ $user }}: {{ $hash }}
{{- else }}
    {}
{{- end }}
  password: {{ $pass | quote }}
  passwordHash: {{ $hash | quote }}
{{- end -}}
```

- [ ] **Step 3: 更新 [values.yaml](../../manifests/values.yaml)，在 `prometheus.server` 段开头插入 webAuth 字段**

定位 [values.yaml#L234](../../manifests/values.yaml#L234)（`server:` 行），在 `fullnameOverride: "prometheus-server"` 之上插入：

```yaml
  server:
    # ---- Web 认证（Basic Auth）----
    # 默认关闭。开启后，Prometheus :9090 所有 HTTP 端点要求 Basic Auth。
    # - 内联模式：填 username/password（明文），chart 自动 bcrypt 哈希为 Secret <release>-prometheus-web-auth；
    #   留空 password 时由 chart 生成 24 位随机；helm upgrade 幂等（lookup 复用旧 hash）。
    # - 外部 Secret 模式：填 existingSecret，chart 不创建 Secret，仅挂载该 Secret；
    #   该 Secret 必须含 web.yml、password、passwordHash 三个 key。
    # 取出当前生效密码：
    #   kubectl -n <ns> get secret <release>-prometheus-web-auth -o jsonpath='{.data.password}' | base64 -d
    webAuth:
      enabled: false
      username: admin
      password: ""
      existingSecret: ""

    fullnameOverride: "prometheus-server"
```

(注：保留原 `fullnameOverride` 行，仅在其前插入 webAuth 段)

- [ ] **Step 4: 验证关闭态行为不变**

```bash
cd manifests
helm dependency update . >/dev/null
helm template t . -n ns --set prometheus.enabled=true | yq 'select(.kind == "Secret" and .metadata.name == "t-prometheus-web-auth") | .stringData."web.yml"'
```

期望输出：`{}\n`（空 web.yml）。

```bash
helm template t . -n ns | yq 'select(.kind == "Secret" and .metadata.name == "t-prometheus-web-auth")'
```

期望输出：空（因为 `prometheus.enabled` 默认 false，模板不渲染）。

- [ ] **Step 5: 验证开启态生成 hash**

```bash
helm template t . -n ns \
  --set prometheus.enabled=true \
  --set prometheus.server.webAuth.enabled=true \
  --set prometheus.server.webAuth.password=secret123 \
  | yq 'select(.kind == "Secret" and .metadata.name == "t-prometheus-web-auth") | .stringData'
```

期望：`web.yml` 含 `basic_auth_users:\n  admin: $2a$...`，`password: "secret123"`，`passwordHash: "$2a$..."`。

- [ ] **Step 6: Commit**

```bash
git add manifests/templates/_helpers.tpl manifests/templates/prometheus-web-auth-secret.yaml manifests/values.yaml
git commit -m "feat(prometheus): add webAuth secret scaffolding (always-on, no-op when disabled)"
```

---

## Task 2: 接通 prometheus 子 chart 挂载

目标：让 prometheus-server 默认挂载 Secret 并加载 `--web.config.file`，实现"切开关无需重新 helm install"。

**Files:**
- Modify: `manifests/values.yaml` (prometheus.server 下追加 extraArgs/extraVolumes/extraVolumeMounts)

- [ ] **Step 1: 在 prometheus.server 下追加默认 overlay**

在 [values.yaml](../../manifests/values.yaml) `prometheus.server` 段内，定位 `extraScrapeConfigs:` 之上，追加：

```yaml
    # ---- 始终挂载 web.yml（关闭态时为空 web.yml = 无认证；与 webAuth.enabled 配合切换）----
    extraArgs:
      web.config.file: /etc/prometheus-web/web.yml
    extraVolumes:
      - name: prometheus-web-auth
        secret:
          secretName: '{{ .Release.Name }}-prometheus-web-auth'
    extraVolumeMounts:
      - name: prometheus-web-auth
        mountPath: /etc/prometheus-web
        readOnly: true
```

> 注意：上面 `secretName` 字段含 `{{ .Release.Name }}` 模板。prometheus-community/prometheus 子 chart 对 `extraVolumes` 不做 `tpl` 渲染。**这里需要改为静态写法**：因为顶层 chart 不能直接 `tpl` 子 chart 的 values，**改用方案**：把 `extraVolumes` 移到子 chart 默认值之外，由本 chart 在 deployment patch 不可行；改用 `existingSecret` 模式时支持用户给定名字。

> 修正方案：使用 `prometheus.server.fullnameOverride: "prometheus-server"` 已固定 prometheus 名，对应地我们也把 webAuth Secret 名固定为 `prometheus-web-auth`（去掉 release 前缀），与 prometheus-server 名保持同款扁平。

- [ ] **Step 2: 修改 helper，把 Secret 名改为固定值**

编辑 [_helpers.tpl](../../manifests/templates/_helpers.tpl) 中刚刚定义的 `webAuthSecretName`：

```gotemplate
{{- define "llm-helm-deployer.webAuthSecretName" -}}
prometheus-web-auth
{{- end -}}
```

> 与 `prometheus-server` / `grafana` 同样采用扁平命名（项目硬约束："核心观测组件必须使用 fullnameOverride 固定名称，不得携带 release 前缀"），既符合既有约定，也使 `extraVolumes.secretName` 可以静态写。

- [ ] **Step 3: 更新 values.yaml extraVolumes 为静态名**

把刚才的 secretName 改为：

```yaml
    extraVolumes:
      - name: prometheus-web-auth
        secret:
          secretName: prometheus-web-auth
```

- [ ] **Step 4: 验证 prometheus Deployment 渲染出挂载与参数**

```bash
helm template t . -n ns --set prometheus.enabled=true \
  | yq 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.containers[0].args' \
  | grep -- "--web.config.file=/etc/prometheus-web/web.yml"

helm template t . -n ns --set prometheus.enabled=true \
  | yq 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.volumes[] | select(.name == "prometheus-web-auth")'
```

期望两条都有匹配输出。

- [ ] **Step 5: 关闭态烟雾验证：渲染产物中 webAuth Secret 内 web.yml 仍为空**

```bash
helm template t . -n ns --set prometheus.enabled=true \
  | yq 'select(.kind == "Secret" and .metadata.name == "prometheus-web-auth") | .stringData."web.yml"'
```

期望：`{}\n`，prometheus 加载后等价无认证。

- [ ] **Step 6: Commit**

```bash
git add manifests/values.yaml manifests/templates/_helpers.tpl
git commit -m "feat(prometheus): mount web.yml from secret with --web.config.file"
```

---

## Task 3: 探针适配（开启态防 401）

目标：开启 webAuth 后 prometheus-server 的 readiness/liveness probe 不被 401 打死。

**Files:**
- Modify: `manifests/values.yaml`

- [ ] **Step 1: 调研子 chart 探针字段**

```bash
helm show values prometheus-community/prometheus --version 29.8.0 | grep -A30 'probeScheme\|readinessProbe\|livenessProbe' | head -60
```

记录 chart 暴露的字段名（典型为 `server.probeScheme`、`server.readinessProbeInitialDelay` 等；29.8.0 暴露 `server.probeHeaders` 列表）。

- [ ] **Step 2: 在 values.yaml `prometheus.server` 下追加 probeHeaders（回退方案：HTTP 探针带 Authorization）**

由 spec 4.3 已确认接受回退到"probeHeaders 注入 Authorization"，直接落到此方案。

```yaml
    # 默认空，仅当 webAuth.enabled=true 时通过 NOTES.txt 提醒用户用下面命令补 probeHeaders：
    #   --set-string "prometheus.server.probeHeaders[0].name=Authorization" \
    #   --set-string "prometheus.server.probeHeaders[0].value=Basic <base64(user:pass)>"
    # 如果你不希望手动 set，留默认空数组并在 webAuth 开启时手动 kubectl edit deployment prometheus-server。
    probeHeaders: []
```

> Helm values 不支持模板，不能直接根据 webAuth.enabled 自动生成 base64 header。把"自动注入"放在 NOTES.txt（Task 8）里以指令形式输出给用户，这是已与用户确认的折中。

- [ ] **Step 3: 验证默认渲染不含 probeHeaders**

```bash
helm template t . -n ns --set prometheus.enabled=true \
  | yq 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.containers[0].readinessProbe.httpGet.httpHeaders'
```

期望：null。

- [ ] **Step 4: 验证显式设置 probeHeaders 可落到 Pod**

```bash
helm template t . -n ns --set prometheus.enabled=true \
  --set 'prometheus.server.probeHeaders[0].name=Authorization' \
  --set 'prometheus.server.probeHeaders[0].value=Basic YWRtaW46c2VjcmV0' \
  | yq 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.containers[0].readinessProbe.httpGet.httpHeaders'
```

期望：含 `name: Authorization`。如果子 chart 字段不是 `probeHeaders` 而是其它名（如 `extraEnvSecrets`），按实际字段调整 values.yaml 注释与本步命令；若子 chart 完全不暴露 probe header 自定义，则 fallback 到 NOTES 文档"用户手动 kubectl patch"。

- [ ] **Step 5: Commit**

```bash
git add manifests/values.yaml
git commit -m "feat(prometheus): expose probeHeaders for Basic Auth probes"
```

---

## Task 4: Grafana datasource 联动

目标：当 grafana.enabled=true 且 webAuth.enabled=true 时，自动在 Grafana datasource 中带上 basicAuth；密码通过 envFromSecret 注入，避免明文进 ConfigMap。

**Files:**
- Create: `manifests/templates/grafana-datasource.yaml`
- Modify: `manifests/values.yaml` (grafana 段：关掉 sub-chart 默认 datasource、加 envFromSecret)

- [ ] **Step 1: 关闭 grafana sub-chart 自带 datasource**

编辑 [values.yaml#L359-L367](../../manifests/values.yaml#L359-L367)，整段 `datasources:` 下置空：

```yaml
  # 由本 chart 模板 templates/grafana-datasource.yaml 接管，
  # 走 sidecar.datasources 自动加载（label=grafana_datasource: "1"），
  # 以便按 webAuth.enabled 条件渲染 basicAuth。
  datasources: {}
```

并把 [values.yaml#L353-L354](../../manifests/values.yaml#L353-L354) 处的 `sidecar.datasources.enabled` 改为 `true`（之前为 false 因为走 datasources 字段）：

```yaml
    datasources:
      enabled: true
      label: grafana_datasource
      labelValue: "1"
      searchNamespace: ALL
```

- [ ] **Step 2: 在 grafana sub-chart 加 envFromSecret 注入密码**

继续在 [values.yaml](../../manifests/values.yaml) grafana 段内追加（位于 sidecar 块之后）：

```yaml
  # 当 webAuth.enabled=true 时，把 prometheus-web-auth Secret 中 password 注入为
  # PROM_BASIC_PASS 环境变量，供 datasource ConfigMap 使用 ${PROM_BASIC_PASS} 引用。
  # 关闭 webAuth 时变量仍存在但不会被 datasource 使用，无副作用。
  envFromSecret: prometheus-web-auth
  # 若需要细粒度控制（仅注入 password 这一 key），可改成 envValueFrom（见 grafana sub-chart 文档）
```

> grafana 子 chart 的 `envFromSecret` 会把 Secret 所有 key 注入为同名 env 变量。Secret 含 `password` / `passwordHash` / `web.yml`，对应 env 是 `password`/`passwordHash`/`web.yml`。后两者无 grafana 用途但不影响。`password` 即所需变量，但环境变量名是 `password`（小写）。datasource 引用须改为 `${password}`。

- [ ] **Step 3: 创建 [grafana-datasource.yaml](../../manifests/templates/grafana-datasource.yaml)**

```gotemplate
{{- /*
自管 Prometheus datasource ConfigMap，由 grafana sidecar 自动加载（label=grafana_datasource: 1）。
- 仅当 grafana.enabled=true 且 prometheus.enabled=true 时渲染，避免无 grafana 场景产生孤立 ConfigMap。
- 当 webAuth.enabled=true 时启用 basicAuth；密码用 ${password} 引用 grafana envFromSecret 注入的 env。
*/ -}}
{{- if and (hasKey .Values "grafana") .Values.grafana.enabled .Values.prometheus.enabled -}}
{{- $auth := eq (include "llm-helm-deployer.webAuthEnabled" .) "true" -}}
{{- $user := .Values.prometheus.server.webAuth.username | default "admin" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}-grafana-datasource
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
    grafana_datasource: "1"
data:
  datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        isDefault: true
        url: http://prometheus-server.{{ .Release.Namespace }}.svc:80
        editable: false
{{- if $auth }}
        basicAuth: true
        basicAuthUser: {{ $user | quote }}
        secureJsonData:
          basicAuthPassword: ${password}
{{- end }}
{{- end -}}
```

- [ ] **Step 4: 验证关闭态 datasource 渲染（不带 basicAuth）**

```bash
helm template t . -n ns --set grafana.enabled=true --set prometheus.enabled=true \
  | yq 'select(.kind == "ConfigMap" and (.metadata.name | test("grafana-datasource$"))) | .data."datasource.yaml"'
```

期望：YAML 含 `name: Prometheus`，**不含** `basicAuth`。

- [ ] **Step 5: 验证开启态 datasource 含 basicAuth**

```bash
helm template t . -n ns --set grafana.enabled=true --set prometheus.enabled=true \
  --set prometheus.server.webAuth.enabled=true \
  --set prometheus.server.webAuth.password=secret123 \
  | yq 'select(.kind == "ConfigMap" and (.metadata.name | test("grafana-datasource$"))) | .data."datasource.yaml"'
```

期望：含 `basicAuth: true`、`basicAuthUser: "admin"`、`basicAuthPassword: ${password}`。

- [ ] **Step 6: Commit**

```bash
git add manifests/templates/grafana-datasource.yaml manifests/values.yaml
git commit -m "feat(grafana): self-managed datasource with conditional Basic Auth"
```

---

## Task 5: helm test 增强

目标：helm test 验证两种模式都能从 prometheus 端点读到正确响应。

**Files:**
- Modify: `manifests/templates/tests/test-connection.yaml`

- [ ] **Step 1: 在 [test-connection.yaml](../../manifests/templates/tests/test-connection.yaml) 末尾追加 prometheus 验证步骤**

替换 `args` 段为：

```yaml
      args:
        - |
          set -e
          URL="http://{{ include "llm-helm-deployer.fullname" . }}:{{ .Values.service.port }}/v1/models"
          {{- if .Values.auth.apiKey }}
          curl -fsS -H "Authorization: Bearer ${VLLM_API_KEY}" "$URL"
          {{- else }}
          curl -fsS "$URL"
          {{- end }}
          {{- if .Values.prometheus.enabled }}
          PROM="http://prometheus-server.{{ .Release.Namespace }}.svc:80/-/ready"
          {{- if eq (include "llm-helm-deployer.webAuthEnabled" .) "true" }}
          # 期望无凭据 401
          code=$(curl -s -o /dev/null -w "%{http_code}" "$PROM")
          [ "$code" = "401" ] || { echo "expected 401 from $PROM, got $code"; exit 1; }
          # 期望带凭据 200
          curl -fsS -u "{{ .Values.prometheus.server.webAuth.username }}:${PROM_PASS}" "$PROM"
          {{- else }}
          curl -fsS "$PROM"
          {{- end }}
          {{- end }}
```

并在 `env:` 段（或新增 env 段）下追加 PROM_PASS 注入：

```yaml
      env:
        {{- if .Values.auth.apiKey }}
        - name: VLLM_API_KEY
          valueFrom:
            secretKeyRef:
              name: {{ include "llm-helm-deployer.fullname" . }}-apikey
              key: api-key
        {{- end }}
        {{- if and .Values.prometheus.enabled (eq (include "llm-helm-deployer.webAuthEnabled" .) "true") }}
        - name: PROM_PASS
          valueFrom:
            secretKeyRef:
              name: {{ include "llm-helm-deployer.webAuthSecretName" . }}
              key: password
        {{- end }}
```

注意：原模板 `env:` 段被 `{{- if .Values.auth.apiKey }}` 整段包裹，需调整为"任一条件成立就渲染 env"的结构：

```yaml
      {{- $needEnv := or .Values.auth.apiKey (and .Values.prometheus.enabled (eq (include "llm-helm-deployer.webAuthEnabled" .) "true")) -}}
      {{- if $needEnv }}
      env:
        ...上面两段 conditional...
      {{- end }}
```

- [ ] **Step 2: 验证模板渲染（不实际 helm test，仅静态确认）**

```bash
helm template t . -n ns --set prometheus.enabled=true --set prometheus.server.webAuth.enabled=true \
  --set prometheus.server.webAuth.password=p \
  | yq 'select(.kind == "Pod" and (.metadata.name | test("test-connection")))'
```

期望：env 含 `PROM_PASS`，args 含 `code=$(curl`。

- [ ] **Step 3: Commit**

```bash
git add manifests/templates/tests/test-connection.yaml
git commit -m "test(helm): verify prometheus 401/200 in helm test for webAuth"
```

---

## Task 6: CI 用例与静态测试断言

**Files:**
- Create: `manifests/ci/auth-on-values.yaml`
- Modify: `tests/helm-static-test.sh`

- [ ] **Step 1: 创建 [ci/auth-on-values.yaml](../../manifests/ci/auth-on-values.yaml)**

```yaml
prometheus:
  enabled: true
  server:
    webAuth:
      enabled: true
      username: admin
      password: testpass-do-not-use-in-prod
grafana:
  enabled: true
```

- [ ] **Step 2: 在 [helm-static-test.sh](../../tests/helm-static-test.sh) 倒数第二行 `pass "all static tests passed"` 之上插入新区块**

```bash
# ---- prometheus webAuth 可选化断言 ----
echo "[7/7] prometheus webAuth on/off renders correctly"

# 关闭态（只开 prometheus）：Secret 渲染但 web.yml 为空，无 basic_auth_users
out=$(helm template t . -n ns --set prometheus.enabled=true)
sec=$(echo "$out" | yq 'select(.kind == "Secret" and .metadata.name == "prometheus-web-auth")')
echo "$sec" | grep -q 'web.yml: |-' || fail "webAuth off: secret missing web.yml key"
if echo "$sec" | grep -q "basic_auth_users"; then fail "webAuth off but basic_auth_users rendered"; fi
pass "webAuth off: empty web.yml"

# 关闭态：prometheus-server Deployment 仍挂载 web.yml + --web.config.file
echo "$out" | yq 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--web.config.file=/etc/prometheus-web/web.yml" \
  || fail "webAuth off: --web.config.file not mounted"
echo "$out" | yq 'select(.kind == "Deployment" and .metadata.name == "prometheus-server") | .spec.template.spec.volumes[].name' \
  | grep -qx "prometheus-web-auth" || fail "webAuth off: web-auth volume missing"
pass "webAuth off: web.yml always-mounted (no-op)"

# 开启态：使用 ci/auth-on-values.yaml
out=$(helm template t . -n ns -f ci/auth-on-values.yaml)
sec=$(echo "$out" | yq 'select(.kind == "Secret" and .metadata.name == "prometheus-web-auth") | .stringData."web.yml"')
echo "$sec" | grep -q "basic_auth_users" || fail "webAuth on: basic_auth_users missing"
echo "$sec" | grep -qE 'admin: \$2[ay]\$' || fail "webAuth on: bcrypt hash missing or malformed"
pass "webAuth on: bcrypt hash rendered"

# 开启态 + grafana：datasource ConfigMap 含 basicAuth
ds=$(echo "$out" | yq 'select(.kind == "ConfigMap" and (.metadata.name | test("grafana-datasource$"))) | .data."datasource.yaml"')
echo "$ds" | grep -q "basicAuth: true" || fail "webAuth on + grafana: basicAuth not rendered"
echo "$ds" | grep -q 'basicAuthUser: "admin"' || fail "webAuth on + grafana: basicAuthUser missing"
echo "$ds" | grep -q 'basicAuthPassword: ${password}' || fail "webAuth on + grafana: password ref missing"
pass "webAuth on + grafana datasource: basicAuth wired"

# 开启态 + grafana：grafana Deployment 含 envFromSecret 引用 prometheus-web-auth
echo "$out" | yq 'select(.kind == "Deployment" and (.metadata.name | test("^grafana$"))) | .spec.template.spec.containers[0].envFrom[]?.secretRef.name' \
  | grep -qx "prometheus-web-auth" || fail "webAuth on + grafana: envFromSecret not wired"
pass "webAuth on + grafana env: PROM password injected"

# helm lint auth-on-values
helm lint . -f ci/auth-on-values.yaml >/dev/null
pass "lint ci/auth-on-values.yaml"
```

并把原文件结尾的 `[6/6]` 编号统一升级为 `[6/7]`，最后总结编号 `[7/7]`。

- [ ] **Step 3: 跑全量静态测试**

```bash
cd /Users/bytedance/go/src/github.com/vienfu/llm-helm-deployer
bash tests/helm-static-test.sh
```

期望：所有 `PASS`，最终输出 `all static tests passed`。

- [ ] **Step 4: Commit**

```bash
git add manifests/ci/auth-on-values.yaml tests/helm-static-test.sh
git commit -m "test(ci): add webAuth on/off helm-static assertions"
```

---

## Task 7: NOTES.txt 与 README

**Files:**
- Modify: `manifests/templates/NOTES.txt`
- Modify: `README.md`

- [ ] **Step 1: 在 NOTES.txt 末尾追加 webAuth 提示**

```
{{- if and .Values.prometheus.enabled (eq (include "llm-helm-deployer.webAuthEnabled" .) "true") }}

[Prometheus Web 认证已开启]
- 当前用户名：{{ .Values.prometheus.server.webAuth.username | default "admin" }}
- 取出当前生效密码：
    kubectl -n {{ .Release.Namespace }} get secret prometheus-web-auth -o jsonpath='{.data.password}' | base64 -d ; echo
- prometheus-server 的 readiness/liveness 探针**默认无认证 header**，会被 401 误杀。请补 probeHeaders：
    PASS=$(kubectl -n {{ .Release.Namespace }} get secret prometheus-web-auth -o jsonpath='{.data.password}' | base64 -d)
    AUTH=$(printf '%s:%s' '{{ .Values.prometheus.server.webAuth.username | default "admin" }}' "$PASS" | base64)
    helm upgrade {{ .Release.Name }} . \
      --set-string "prometheus.server.probeHeaders[0].name=Authorization" \
      --set-string "prometheus.server.probeHeaders[0].value=Basic $AUTH" \
      --reuse-values
- 浏览器访问：kubectl -n {{ .Release.Namespace }} port-forward svc/prometheus-server 9090:80
{{- end }}
```

- [ ] **Step 2: 在 [README.md](../../README.md) 监控章节末尾追加小节**

文本（Markdown）：

```markdown
### Prometheus Web 认证（可选）

默认关闭。开启后，Prometheus :9090 全部 HTTP 端点要求 Basic Auth；Grafana datasource 自动联动。

最小配置：

```yaml
prometheus:
  enabled: true
  server:
    webAuth:
      enabled: true
      username: admin
      password: ""        # 留空时 chart 自动生成 24 位随机密码
```

取出当前密码：

```bash
kubectl -n <ns> get secret prometheus-web-auth -o jsonpath='{.data.password}' | base64 -d
```

补 probe 凭据（**必须**，否则 readiness/liveness 探针被 401 杀）：

```bash
PASS=$(kubectl -n <ns> get secret prometheus-web-auth -o jsonpath='{.data.password}' | base64 -d)
AUTH=$(printf 'admin:%s' "$PASS" | base64)
helm upgrade <release> manifests/ \
  --set-string "prometheus.server.probeHeaders[0].name=Authorization" \
  --set-string "prometheus.server.probeHeaders[0].value=Basic $AUTH" \
  --reuse-values
```

外部 Secret 模式（不让 chart 接触明文）：

```yaml
prometheus:
  server:
    webAuth:
      enabled: true
      existingSecret: my-prom-auth   # 必须含 web.yml / password / passwordHash 三个 key
```
```

- [ ] **Step 3: Commit**

```bash
git add manifests/templates/NOTES.txt README.md
git commit -m "docs(prometheus): add webAuth quickstart and probe header note"
```

---

## Task 8: 兜底自检与归档

- [ ] **Step 1: 全量 lint + static-test 一次**

```bash
cd /Users/bytedance/go/src/github.com/vienfu/llm-helm-deployer
bash tests/helm-static-test.sh
helm lint manifests/ -f manifests/ci/auth-on-values.yaml
helm lint manifests/ -f manifests/ci/default-values.yaml
helm lint manifests/ -f manifests/ci/auth-values.yaml
helm lint manifests/ -f manifests/ci/ingress-values.yaml
helm lint manifests/ -f manifests/ci/tp2-values.yaml
```

期望：全部通过。

- [ ] **Step 2: 验收清单走查**（对照 spec §8）

逐条勾选 [spec §8](../specs/2026-06-11-prometheus-web-auth-design.md) 验收清单中的"静态可验证"条目（其余实集群项标 N/A 留 PR review 时复核）：

- [x] `webAuth.enabled=false` 默认下 `helm template` 输出与 baseline diff 仅含新增的"空 web.yml" Secret 与 prometheus-server 的 web.config.file 参数（**预期变更**，与 baseline 不一致是设计意图）。
- [x] `webAuth.enabled=true` 内联模式静态渲染含 bcrypt hash。
- [x] grafana datasource basicAuth 联动。
- [N/A] 探针 401 不杀 Pod —— 由 NOTES + README 引导用户后置注入 probeHeaders；spec §7 已说明此为已确认的折中。
- [x] CI auth-on-values.yaml lint + template 通过。

- [ ] **Step 3: 把 spec 状态从"草案"改为"已实现"**

编辑 [docs/superpowers/specs/2026-06-11-prometheus-web-auth-design.md](../specs/2026-06-11-prometheus-web-auth-design.md) 第 5 行：

```
- 状态：已实现（v0.x.y）
```

- [ ] **Step 4: 最终 commit**

```bash
git add docs/superpowers/specs/2026-06-11-prometheus-web-auth-design.md
git commit -m "docs(spec): mark prometheus webAuth design as implemented"
```

---

## 自检（plan-level）

- 覆盖 spec §3 ~ §6 全部条目（值接口 / Secret / 子 chart 透传 / 探针 / Grafana 联动 / helm test / CI / 文档）。
- spec §4.2 "always-on overlay" 已落到 Task 2；§4.3 探针适配选定回退方案（probeHeaders + NOTES 引导）已与用户确认。
- 命名一致性：Secret 名固定 `prometheus-web-auth`（与 `prometheus-server` / `grafana` 保持扁平命名硬约束一致），所有模板与测试断言统一引用此名。
- helper `webAuthEnabled` 在 Task 1 定义，Task 4 / 5 / 7 持续复用，签名一致。
- 风险：grafana sub-chart `envFromSecret` 字段名以实际版本为准（grafana-12.4.1 chart 文档为 `envFromSecret`），Task 4 Step 5 的静态断言会守门，若字段名不符则 CI 立即 fail，能在第一时间暴露并修正。
