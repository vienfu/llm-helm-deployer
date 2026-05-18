# llm-helm-deployer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个一键部署 vLLM 文本模型的 Helm Chart，对外提供 OpenAI 兼容 API 与 Prometheus 指标。

**Architecture:** 单 chart / 单模型 / 单副本；hostPath 加载权重；ClusterIP Service + 可选 Ingress；ServiceMonitor 暴露 vLLM `/metrics`，GPU 显存指标复用集群 dcgm-exporter。`vllm.tensorParallelSize` 自动同步到 `nvidia.com/gpu` 资源请求。

**Tech Stack:** Helm v3、Kubernetes（NVIDIA device plugin、Prometheus Operator、dcgm-exporter）、官方镜像 `vllm/vllm-openai`、`helm lint` / `helm template` / `kubeconform` / `yq` 做静态校验。

参考设计文档: `docs/superpowers/specs/2026-05-18-llm-helm-deployer-design.md`

---

## File Structure

| 文件 | 作用 |
|------|------|
| `Chart.yaml` | Chart 元数据 |
| `values.yaml` | 默认配置；按 spec §5 抽象 |
| `.helmignore` | 忽略非渲染文件 |
| `README.md` | 用户文档：前置依赖、安装、示例、values 字段表 |
| `templates/_helpers.tpl` | 命名/标签/`vllmArgs`/`gpuCount`/`servedModelName` 模板函数 |
| `templates/NOTES.txt` | 安装后输出 curl 示例 |
| `templates/serviceaccount.yaml` | ServiceAccount |
| `templates/secret-apikey.yaml` | 条件渲染：`auth.apiKey` 非空时创建 Secret |
| `templates/deployment.yaml` | 唯一的 Deployment（replicas=1, Recreate） |
| `templates/service.yaml` | ClusterIP Service，端口名 `http=8000` |
| `templates/ingress.yaml` | 条件渲染：`ingress.enabled` 时创建 |
| `templates/servicemonitor.yaml` | 条件渲染：`metrics.serviceMonitor.enabled` |
| `templates/grafana-dashboard.yaml` | 条件渲染：`metrics.grafanaDashboard.enabled` |
| `templates/tests/test-connection.yaml` | `helm test` 用 |
| `dashboards/vllm-overview.json` | Grafana dashboard 占位（最小 JSON） |
| `ci/default-values.yaml` | 静态测试场景 |
| `ci/ingress-values.yaml` | 静态测试场景 |
| `ci/auth-values.yaml` | 静态测试场景 |
| `ci/tp2-values.yaml` | 静态测试场景 |
| `tests/helm-static-test.sh` | 跑 lint + template + 断言的 shell 脚本（项目自测） |

---

## Task 1: 初始化 Chart 骨架

**Files:**
- Create: `Chart.yaml`
- Create: `.helmignore`

- [ ] **Step 1: 写 `Chart.yaml`**

```yaml
apiVersion: v2
name: llm-helm-deployer
description: One-click Helm chart to deploy a text LLM with vLLM (NVIDIA GPU, OpenAI-compatible API).
type: application
version: 0.1.0
appVersion: "v0.6.3"
keywords:
  - llm
  - vllm
  - openai
  - gpu
  - inference
home: https://github.com/vienfu/llm-helm-deployer
sources:
  - https://github.com/vienfu/llm-helm-deployer
maintainers:
  - name: vienfu
```

- [ ] **Step 2: 写 `.helmignore`**

```
# Patterns to ignore when building packages.
.DS_Store
.git/
.gitignore
.idea/
.vscode/
*.swp
*.tmp
*.bak
*.orig
docs/
tests/
```

- [ ] **Step 3: 验证**

Run: `helm lint .`
Expected: `1 chart(s) linted, 0 chart(s) failed`（注意此时还没 values.yaml，会提示 values.yaml 缺失，可暂时忽略，下一任务补齐后再 lint）

- [ ] **Step 4: Commit**

```bash
git add Chart.yaml .helmignore
git commit -m "chore: init helm chart skeleton"
```

---

## Task 2: 编写默认 `values.yaml`

**Files:**
- Create: `values.yaml`

- [ ] **Step 1: 写 `values.yaml`（与 spec §5 完全一致）**

```yaml
image:
  repository: vllm/vllm-openai
  tag: v0.6.3
  pullPolicy: IfNotPresent
imagePullSecrets: []

nameOverride: ""
fullnameOverride: ""

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
    nvidia.com/gpu: 1
  requests: {}
nodeSelector: {}
tolerations: []
affinity: {}

probes:
  startup:
    enabled: true
    failureThreshold: 60
    periodSeconds: 10
    httpGet:
      path: /health
      port: 8000
  readiness:
    enabled: true
    periodSeconds: 10
    httpGet:
      path: /health
      port: 8000
  liveness:
    enabled: true
    periodSeconds: 30
    httpGet:
      path: /health
      port: 8000

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

serviceAccount:
  create: true
  name: ""
  annotations: {}
```

- [ ] **Step 2: 验证 `helm lint`**

Run: `helm lint .`
Expected: `1 chart(s) linted, 0 chart(s) failed`（可能 INFO 级提示 templates 目录为空，先忽略）

- [ ] **Step 3: Commit**

```bash
git add values.yaml
git commit -m "feat: add default values.yaml"
```

---

## Task 3: 写 `_helpers.tpl`

**Files:**
- Create: `templates/_helpers.tpl`

- [ ] **Step 1: 写命名 / 标签模板**

```gotemplate
{{/*
Expand the name of the chart.
*/}}
{{- define "llm-helm-deployer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "llm-helm-deployer.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "llm-helm-deployer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llm-helm-deployer.labels" -}}
helm.sh/chart: {{ include "llm-helm-deployer.chart" . }}
{{ include "llm-helm-deployer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "llm-helm-deployer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "llm-helm-deployer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "llm-helm-deployer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "llm-helm-deployer.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 2: 追加 vLLM 相关辅助函数**

```gotemplate
{{/*
GPU 数量 = tensorParallelSize
*/}}
{{- define "llm-helm-deployer.gpuCount" -}}
{{- .Values.vllm.tensorParallelSize | int -}}
{{- end -}}

{{/*
servedModelName: 用户填了取用户的；否则取 model.name 的 basename
*/}}
{{- define "llm-helm-deployer.servedModelName" -}}
{{- if .Values.model.servedName -}}
{{- .Values.model.servedName -}}
{{- else -}}
{{- .Values.model.name | base -}}
{{- end -}}
{{- end -}}

{{/*
拼接 vLLM 启动参数列表（YAML 数组形式）
*/}}
{{- define "llm-helm-deployer.vllmArgs" -}}
- --model
- {{ .Values.model.name | quote }}
- --served-model-name
- {{ include "llm-helm-deployer.servedModelName" . | quote }}
- --host
- "0.0.0.0"
- --port
- {{ .Values.vllm.port | quote }}
- --tensor-parallel-size
- {{ .Values.vllm.tensorParallelSize | quote }}
- --gpu-memory-utilization
- {{ .Values.vllm.gpuMemoryUtilization | quote }}
{{- if .Values.vllm.maxModelLen }}
- --max-model-len
- {{ .Values.vllm.maxModelLen | quote }}
{{- end }}
{{- if .Values.vllm.dtype }}
- --dtype
- {{ .Values.vllm.dtype | quote }}
{{- end }}
{{- if .Values.vllm.trustRemoteCode }}
- --trust-remote-code
{{- end }}
{{- if .Values.auth.apiKey }}
- --api-key
- $(VLLM_API_KEY)
{{- end }}
{{- range .Values.vllm.extraArgs }}
- {{ . | quote }}
{{- end }}
{{- end -}}
```

- [ ] **Step 3: 验证 `helm lint`**

Run: `helm lint .`
Expected: 0 failed

- [ ] **Step 4: Commit**

```bash
git add templates/_helpers.tpl
git commit -m "feat: add helpers for naming, labels, gpu count and vllm args"
```

---

## Task 4: ServiceAccount 模板

**Files:**
- Create: `templates/serviceaccount.yaml`

- [ ] **Step 1: 写模板**

```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "llm-helm-deployer.serviceAccountName" . }}
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

- [ ] **Step 2: 验证渲染**

Run: `helm template release-test . | grep -A4 'kind: ServiceAccount'`
Expected: 看到 ServiceAccount 资源被渲染

- [ ] **Step 3: Commit**

```bash
git add templates/serviceaccount.yaml
git commit -m "feat: add service account template"
```

---

## Task 5: Secret（API Key）模板

**Files:**
- Create: `templates/secret-apikey.yaml`

- [ ] **Step 1: 写模板**

```yaml
{{- if .Values.auth.apiKey -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}-apikey
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
type: Opaque
data:
  api-key: {{ .Values.auth.apiKey | b64enc | quote }}
{{- end }}
```

- [ ] **Step 2: 验证条件渲染**

Run: `helm template release-test . | grep -c 'kind: Secret' || true`
Expected: `0`（默认 apiKey 为空）

Run: `helm template release-test . --set auth.apiKey=hello | grep 'kind: Secret'`
Expected: 看到 Secret 资源

- [ ] **Step 3: Commit**

```bash
git add templates/secret-apikey.yaml
git commit -m "feat: optional api-key secret"
```

---

## Task 6: Deployment 模板

**Files:**
- Create: `templates/deployment.yaml`

- [ ] **Step 1: 写模板**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "llm-helm-deployer.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "llm-helm-deployer.selectorLabels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "llm-helm-deployer.serviceAccountName" . }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      volumes:
        - name: model-store
          hostPath:
            path: {{ .Values.model.hostPath.path | quote }}
            type: {{ .Values.model.hostPath.type | quote }}
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: {{ .Values.shm.sizeLimit }}
      containers:
        - name: vllm
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- with .Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          args:
            {{- include "llm-helm-deployer.vllmArgs" . | nindent 12 }}
          env:
            - name: HF_HUB_OFFLINE
              value: "1"
            {{- if .Values.auth.apiKey }}
            - name: VLLM_API_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ include "llm-helm-deployer.fullname" . }}-apikey
                  key: api-key
            {{- end }}
          ports:
            - name: http
              containerPort: {{ .Values.vllm.port }}
              protocol: TCP
          volumeMounts:
            - name: model-store
              mountPath: {{ .Values.model.hostPath.mountPath }}
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
          resources:
            limits:
              nvidia.com/gpu: {{ include "llm-helm-deployer.gpuCount" . }}
              {{- with .Values.resources.limits }}
              {{- range $k, $v := . }}
              {{- if ne $k "nvidia.com/gpu" }}
              {{ $k }}: {{ $v }}
              {{- end }}
              {{- end }}
              {{- end }}
            {{- with .Values.resources.requests }}
            requests:
              {{- toYaml . | nindent 14 }}
            {{- end }}
          {{- if .Values.probes.startup.enabled }}
          startupProbe:
            httpGet:
              path: {{ .Values.probes.startup.httpGet.path }}
              port: {{ .Values.probes.startup.httpGet.port }}
            failureThreshold: {{ .Values.probes.startup.failureThreshold }}
            periodSeconds: {{ .Values.probes.startup.periodSeconds }}
          {{- end }}
          {{- if .Values.probes.readiness.enabled }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readiness.httpGet.path }}
              port: {{ .Values.probes.readiness.httpGet.port }}
            periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
          {{- end }}
          {{- if .Values.probes.liveness.enabled }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.liveness.httpGet.path }}
              port: {{ .Values.probes.liveness.httpGet.port }}
            periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
          {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

- [ ] **Step 2: 验证默认渲染**

Run: `helm template release-test . | yq '.kind' -`
Expected: 输出包含 `Deployment`、`Service`（暂未建）等。先只关心 Deployment 不报错。

Run: `helm template release-test . | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits."nvidia.com/gpu"'`
Expected: `1`

Run: `helm template release-test . --set vllm.tensorParallelSize=2 | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits."nvidia.com/gpu"'`
Expected: `2`

Run: `helm template release-test . --set vllm.tensorParallelSize=2 | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args' -`
Expected: 数组中包含 `--tensor-parallel-size` 与紧随的 `"2"`

- [ ] **Step 3: Commit**

```bash
git add templates/deployment.yaml
git commit -m "feat: add deployment template with hostPath model and gpu sync"
```

---

## Task 7: Service 模板

**Files:**
- Create: `templates/service.yaml`

- [ ] **Step 1: 写模板**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
  {{- with .Values.service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- include "llm-helm-deployer.selectorLabels" . | nindent 4 }}
```

- [ ] **Step 2: 验证**

Run: `helm template release-test . | yq 'select(.kind == "Service") | .spec.ports[0].name'`
Expected: `http`

- [ ] **Step 3: Commit**

```bash
git add templates/service.yaml
git commit -m "feat: add ClusterIP service"
```

---

## Task 8: Ingress 模板

**Files:**
- Create: `templates/ingress.yaml`

- [ ] **Step 1: 写模板**

```yaml
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  {{- with .Values.ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ include "llm-helm-deployer.fullname" $ }}
                port:
                  number: {{ $.Values.service.port }}
          {{- end }}
    {{- end }}
{{- end }}
```

- [ ] **Step 2: 验证条件渲染**

Run: `helm template release-test . | grep -c 'kind: Ingress' || true`
Expected: `0`

Run: `helm template release-test . --set ingress.enabled=true | grep 'kind: Ingress'`
Expected: `kind: Ingress`

- [ ] **Step 3: Commit**

```bash
git add templates/ingress.yaml
git commit -m "feat: optional ingress"
```

---

## Task 9: ServiceMonitor 模板

**Files:**
- Create: `templates/servicemonitor.yaml`

- [ ] **Step 1: 写模板**

```yaml
{{- if .Values.metrics.serviceMonitor.enabled -}}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
    {{- with .Values.metrics.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "llm-helm-deployer.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      path: /metrics
      interval: {{ .Values.metrics.serviceMonitor.interval }}
      {{- with .Values.metrics.serviceMonitor.relabelings }}
      relabelings:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
```

- [ ] **Step 2: 验证**

Run: `helm template release-test . | grep 'kind: ServiceMonitor'`
Expected: `kind: ServiceMonitor`

Run: `helm template release-test . --set metrics.serviceMonitor.enabled=false | grep -c 'kind: ServiceMonitor' || true`
Expected: `0`

- [ ] **Step 3: Commit**

```bash
git add templates/servicemonitor.yaml
git commit -m "feat: prometheus servicemonitor for /metrics"
```

---

## Task 10: Grafana Dashboard ConfigMap + JSON

**Files:**
- Create: `dashboards/vllm-overview.json`
- Create: `templates/grafana-dashboard.yaml`

- [ ] **Step 1: 写一个最小可用 Dashboard JSON**

```json
{
  "title": "vLLM Overview",
  "schemaVersion": 38,
  "version": 1,
  "panels": [
    {
      "type": "timeseries",
      "title": "TTFT (p95)",
      "targets": [
        { "expr": "histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[5m])))" }
      ],
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 }
    },
    {
      "type": "timeseries",
      "title": "TPOT (p95)",
      "targets": [
        { "expr": "histogram_quantile(0.95, sum by (le) (rate(vllm:time_per_output_token_seconds_bucket[5m])))" }
      ],
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 }
    },
    {
      "type": "timeseries",
      "title": "Throughput (success/s)",
      "targets": [
        { "expr": "sum(rate(vllm:request_success_total[1m]))" }
      ],
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 }
    },
    {
      "type": "timeseries",
      "title": "GPU Memory Used (bytes)",
      "targets": [
        { "expr": "DCGM_FI_DEV_FB_USED" }
      ],
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 }
    }
  ]
}
```

- [ ] **Step 2: 写模板**

```yaml
{{- if .Values.metrics.grafanaDashboard.enabled -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "llm-helm-deployer.fullname" . }}-dashboard
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
    grafana_dashboard: "1"
data:
  vllm-overview.json: |-
{{ .Files.Get "dashboards/vllm-overview.json" | indent 4 }}
{{- end }}
```

- [ ] **Step 3: 验证**

Run: `helm template release-test . --set metrics.grafanaDashboard.enabled=true | grep grafana_dashboard`
Expected: 看到 `grafana_dashboard: "1"`

- [ ] **Step 4: Commit**

```bash
git add dashboards/vllm-overview.json templates/grafana-dashboard.yaml
git commit -m "feat: optional grafana dashboard configmap"
```

---

## Task 11: NOTES.txt

**Files:**
- Create: `templates/NOTES.txt`

- [ ] **Step 1: 写 NOTES**

```
1. 等待 Pod 就绪：
   kubectl --namespace {{ .Release.Namespace }} rollout status deployment/{{ include "llm-helm-deployer.fullname" . }}

2. 端口转发到本地：
   kubectl --namespace {{ .Release.Namespace }} port-forward svc/{{ include "llm-helm-deployer.fullname" . }} 8000:{{ .Values.service.port }}

3. 列出模型：
   curl http://127.0.0.1:8000/v1/models{{- if .Values.auth.apiKey }} -H "Authorization: Bearer <YOUR_API_KEY>"{{- end }}

4. Chat completion：
   curl http://127.0.0.1:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     {{- if .Values.auth.apiKey }}-H "Authorization: Bearer <YOUR_API_KEY>" \{{- end }}
     -d '{
       "model": "{{ include "llm-helm-deployer.servedModelName" . }}",
       "messages": [{"role":"user","content":"hello"}]
     }'

5. /metrics 端点（被 ServiceMonitor 抓取）：
   curl http://127.0.0.1:8000/metrics | head
```

- [ ] **Step 2: 验证**

Run: `helm install release-test . --dry-run --debug 2>&1 | grep -A2 'NOTES:'`
Expected: 看到 NOTES 内容渲染

- [ ] **Step 3: Commit**

```bash
git add templates/NOTES.txt
git commit -m "docs: post-install notes with curl examples"
```

---

## Task 12: helm test 资源

**Files:**
- Create: `templates/tests/test-connection.yaml`

- [ ] **Step 1: 写模板**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "llm-helm-deployer.fullname" . }}-test-connection"
  labels:
    {{- include "llm-helm-deployer.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          URL="http://{{ include "llm-helm-deployer.fullname" . }}:{{ .Values.service.port }}/v1/models"
          {{- if .Values.auth.apiKey }}
          curl -fsS -H "Authorization: Bearer $(VLLM_API_KEY)" "$URL"
          {{- else }}
          curl -fsS "$URL"
          {{- end }}
      {{- if .Values.auth.apiKey }}
      env:
        - name: VLLM_API_KEY
          valueFrom:
            secretKeyRef:
              name: {{ include "llm-helm-deployer.fullname" . }}-apikey
              key: api-key
      {{- end }}
```

- [ ] **Step 2: 验证渲染**

Run: `helm template release-test . | grep helm.sh/hook`
Expected: 看到 `"helm.sh/hook": test`

- [ ] **Step 3: Commit**

```bash
git add templates/tests/test-connection.yaml
git commit -m "test: helm test pod that curls /v1/models"
```

---

## Task 13: ci/* 多场景 values

**Files:**
- Create: `ci/default-values.yaml`
- Create: `ci/ingress-values.yaml`
- Create: `ci/auth-values.yaml`
- Create: `ci/tp2-values.yaml`

- [ ] **Step 1: 写 `ci/default-values.yaml`**

```yaml
# 与默认 values 一致，留空即可
```

- [ ] **Step 2: 写 `ci/ingress-values.yaml`**

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: llm.test.local
      paths:
        - path: /
          pathType: Prefix
```

- [ ] **Step 3: 写 `ci/auth-values.yaml`**

```yaml
auth:
  apiKey: "test-secret-key"
```

- [ ] **Step 4: 写 `ci/tp2-values.yaml`**

```yaml
vllm:
  tensorParallelSize: 2
```

- [ ] **Step 5: 验证 lint 全绿**

Run:

```bash
for f in ci/*-values.yaml; do
  echo "=== $f ==="
  helm lint . -f "$f"
done
```

Expected: 每个都 `0 chart(s) failed`

- [ ] **Step 6: Commit**

```bash
git add ci/
git commit -m "test: add ci values for default/ingress/auth/tp2"
```

---

## Task 14: 静态测试脚本

**Files:**
- Create: `tests/helm-static-test.sh`

- [ ] **Step 1: 写脚本（含断言）**

```bash
#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$CHART_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"
}
require helm
require yq

echo "[1/4] helm lint on all ci scenarios"
for f in ci/*-values.yaml; do
  helm lint . -f "$f" >/dev/null
  pass "lint $f"
done

echo "[2/4] tensorParallelSize=2 should sync nvidia.com/gpu and --tensor-parallel-size"
out=$(helm template t . -f ci/tp2-values.yaml)
gpu=$(echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits."nvidia.com/gpu"')
[ "$gpu" = "2" ] || fail "expected gpu=2, got $gpu"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--tensor-parallel-size 2" || fail "args missing --tensor-parallel-size 2"
pass "tp2 sync"

echo "[3/4] auth.apiKey present should produce Secret + env + --api-key; absent should not"
out=$(helm template t . -f ci/auth-values.yaml)
echo "$out" | yq 'select(.kind == "Secret")' | grep -q api-key || fail "auth: missing Secret"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' \
  | grep -q VLLM_API_KEY || fail "auth: missing VLLM_API_KEY env"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--api-key" || fail "auth: missing --api-key arg"
pass "auth on"

out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | yq 'select(.kind == "Secret")' | grep -q api-key; then
  fail "auth off but Secret rendered"
fi
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | join(" ")' \
  | grep -q -- "--api-key" && fail "auth off but --api-key rendered"
pass "auth off"

echo "[4/4] ingress + servicemonitor toggles"
out=$(helm template t . -f ci/ingress-values.yaml)
echo "$out" | grep -q "kind: Ingress" || fail "ingress on but not rendered"
out=$(helm template t . -f ci/default-values.yaml)
if echo "$out" | grep -q "kind: Ingress"; then fail "ingress off but rendered"; fi
echo "$out" | grep -q "kind: ServiceMonitor" || fail "ServiceMonitor should default on"

# hostPath path/mountPath transparent
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "model-store") | .hostPath.path' \
  | grep -q "/data/models" || fail "hostPath path mismatch"
echo "$out" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "model-store") | .mountPath' \
  | grep -q "/models" || fail "hostPath mountPath mismatch"

pass "all static tests passed"
```

- [ ] **Step 2: 赋可执行 + 跑一次**

Run:

```bash
chmod +x tests/helm-static-test.sh
./tests/helm-static-test.sh
```

Expected: 全部 PASS，最后一行 `PASS: all static tests passed`

- [ ] **Step 3: Commit**

```bash
git add tests/helm-static-test.sh
git commit -m "test: static rendering assertions for chart"
```

---

## Task 15: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: 写 README**

````markdown
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
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with prerequisites, quickstart, values table"
```

---

## Task 16: 全量回归

**Files:**
- 无新增

- [ ] **Step 1: 完整回归**

Run:

```bash
helm lint .
./tests/helm-static-test.sh
helm template t . | kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.29.0
```

Expected:

- `helm lint`: `0 chart(s) failed`
- 静态脚本：`PASS: all static tests passed`
- `kubeconform`: 0 errors（`monitoring.coreos.com` 等 CRD 用 `-ignore-missing-schemas` 跳过）

> 如果环境没有 `kubeconform`，可跳过该步并在 README/CI 上注明。

- [ ] **Step 2: 标记版本（可选，由用户决定）**

```bash
git tag v0.1.0
```

---

## Self-Review

**Spec coverage：**

- §1 项目定位 → README + Chart.yaml（Task 1, 15）
- §2 MVP（replicas=1 / Recreate）→ Deployment（Task 6）
- §3 架构 + 依赖前置 → README 前置依赖段（Task 15）
- §4 hostPath 模型加载 → Deployment volumes / volumeMounts + HF_HUB_OFFLINE（Task 6）
- §5 values 抽象 → values.yaml（Task 2）
- §6 模板文件结构 → Tasks 3–13 全部覆盖
- §7 关键模板逻辑（vllmArgs/gpuCount/servedModelName）→ Task 3
- §8 指标/监控 → ServiceMonitor + Grafana ConfigMap（Task 9, 10）
- §9 测试策略（lint/template/yq 断言、helm test）→ Task 12, 14, 16
- §10 安全/健壮性约束（apiKey via env、readOnly mount、HF_HUB_OFFLINE、grace period、startup probe 预算）→ Task 5, 6
- §11 后续迭代 → README "已知限制" + spec 文档保留

**Placeholder scan：** 所有步骤均含具体内容；命令均给出 expected。

**Type/命名一致性：** `llm-helm-deployer.fullname`/`servedModelName`/`gpuCount`/`vllmArgs` 全文统一；`http` 端口名贯穿 Service / ServiceMonitor / Deployment / probes。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-18-llm-helm-deployer.md`. Two execution options:

1. **Subagent-Driven (recommended)** — 每个 Task 派一个新 subagent，任务间评审，迭代快。
2. **Inline Execution** — 在当前会话里按 `executing-plans` skill 批量执行，带检查点。

Which approach?
