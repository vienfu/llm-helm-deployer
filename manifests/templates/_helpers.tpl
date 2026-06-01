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
vLLM 容器完整镜像引用：global.imageRegistry 非空时拼前缀；否则 image.repository 原样使用。
当 image.repository 已含 '/' 形式的 registry（如 my-reg.io/vllm/vllm-openai）时也兼容（用户自填覆盖）。
*/}}
{{- define "llm-helm-deployer.image" -}}
{{- $reg := "" -}}
{{- if .Values.global -}}
{{- $reg = .Values.global.imageRegistry | default "" -}}
{{- end -}}
{{- if $reg -}}
{{- printf "%s/%s:%s" $reg .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
合并的 imagePullSecrets：主 chart imagePullSecrets + global.imagePullSecrets。
两处都可填；模板里 union 后输出。
*/}}
{{- define "llm-helm-deployer.imagePullSecrets" -}}
{{- $secrets := list -}}
{{- range .Values.imagePullSecrets -}}
{{- $secrets = append $secrets . -}}
{{- end -}}
{{- if and .Values.global .Values.global.imagePullSecrets -}}
{{- range .Values.global.imagePullSecrets -}}
{{- $secrets = append $secrets . -}}
{{- end -}}
{{- end -}}
{{- if $secrets -}}
{{- toYaml $secrets -}}
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
{{- if .Values.vllm.maxNumSeqs }}
- --max-num-seqs
- {{ .Values.vllm.maxNumSeqs | quote }}
{{- end }}
{{- if .Values.vllm.dtype }}
- --dtype
- {{ .Values.vllm.dtype | quote }}
{{- end }}
{{- if .Values.vllm.trustRemoteCode }}
- --trust-remote-code
{{- end }}
{{- /* ---- 通用性能调优 ---- */}}
{{- if .Values.vllm.enablePrefixCaching }}
- --enable-prefix-caching
{{- end }}
{{- if kindIs "bool" .Values.vllm.enableChunkedPrefill }}
{{- if .Values.vllm.enableChunkedPrefill }}
- --enable-chunked-prefill
{{- else }}
- --no-enable-chunked-prefill
{{- end }}
{{- end }}
{{- if .Values.vllm.maxNumBatchedTokens }}
- --max-num-batched-tokens
- {{ .Values.vllm.maxNumBatchedTokens | quote }}
{{- end }}
{{- if .Values.vllm.maxNumPartialPrefills }}
- --max-num-partial-prefills
- {{ .Values.vllm.maxNumPartialPrefills | quote }}
{{- end }}
{{- if ne (toString (.Values.vllm.swapSpace | default "")) "" }}
- --swap-space
- {{ .Values.vllm.swapSpace | quote }}
{{- end }}
{{- if .Values.vllm.blockSize }}
- --block-size
- {{ .Values.vllm.blockSize | quote }}
{{- end }}
{{- if .Values.vllm.kvCacheDtype }}
- --kv-cache-dtype
- {{ .Values.vllm.kvCacheDtype | quote }}
{{- end }}
{{- if .Values.vllm.calculateKvScales }}
- --calculate-kv-scales
{{- end }}
{{- if .Values.vllm.disableLogRequests }}
- --disable-log-requests
{{- end }}
{{- if .Values.vllm.enforceEager }}
- --enforce-eager
{{- end }}
{{- /* ---- 量化 ---- */}}
{{- if .Values.vllm.quantization }}
- --quantization
- {{ .Values.vllm.quantization | quote }}
{{- end }}
{{- /* ---- 编译优化 ---- */}}
{{- if ne (toString (.Values.vllm.compilationLevel | default "")) "" }}
- {{ printf "-O%v" .Values.vllm.compilationLevel | quote }}
{{- end }}
{{- /* ---- MoE ---- */}}
{{- if and .Values.vllm.moe .Values.vllm.moe.enableExpertParallel }}
- --enable-expert-parallel
{{- if .Values.vllm.moe.expertParallelSize }}
- --expert-parallel-size
- {{ .Values.vllm.moe.expertParallelSize | quote }}
{{- end }}
{{- end }}
{{- if and .Values.vllm.moe .Values.vllm.moe.enableEplb }}
- --enable-eplb
{{- end }}
{{- /* ---- 推测解码 / MTP ---- */}}
{{- if and .Values.vllm.speculative .Values.vllm.speculative.enabled }}
{{- if .Values.vllm.speculative.config }}
- --speculative-config
- {{ .Values.vllm.speculative.config | quote }}
{{- else if .Values.vllm.speculative.model }}
- --speculative-model
- {{ .Values.vllm.speculative.model | quote }}
{{- if .Values.vllm.speculative.numTokens }}
- --num-speculative-tokens
- {{ .Values.vllm.speculative.numTokens | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- if .Values.auth.apiKey }}
- --api-key
- $(VLLM_API_KEY)
{{- end }}
{{- range .Values.vllm.extraArgs }}
- {{ . | quote }}
{{- end }}
{{- end -}}
