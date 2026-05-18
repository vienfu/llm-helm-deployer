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
