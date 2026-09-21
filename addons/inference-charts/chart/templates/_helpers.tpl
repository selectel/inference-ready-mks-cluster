{{/*
Expand the name of the chart.
*/}}
{{- define "inference-charts.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "inference-charts.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "inference-charts.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "inference-charts.labels" -}}
helm.sh/chart: {{ include "inference-charts.chart" . }}
{{ include "inference-charts.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "inference-charts.selectorLabels" -}}
app.kubernetes.io/name: {{ include "inference-charts.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels for VLLM
*/}}
{{- define "inference-charts.vllmComponentLabels" -}}
app.kubernetes.io/component: {{.Values.inference.serviceName}}
{{- end }}

{{/*
Component labels for Ray-VLLM
*/}}
{{- define "inference-charts.rayVllmComponentLabels" -}}
app.kubernetes.io/component: {{.Values.inference.serviceName}}
{{- end }}

{{- define "inference-charts.modelParameters" -}}
{{- $modelParameters := .Values.modelParameters -}}
{{- $args := list -}}
{{ $tpsize := 1 -}}
{{- range $key, $value := $modelParameters -}}
  {{- if kindIs "bool" $value -}}
    {{- if $value -}}
      {{- $args = append $args (printf "--%s" ($key | kebabcase)) -}}
    {{- end -}}
  {{- else -}}
    {{- $args = append $args (printf "--%s %s" ($key | kebabcase) $value) -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.inference.framework "aibrix" }}
    {{- $args = append $args (printf "--served-model-name %s" .Values.inference.serviceName) }}
{{- else if .Values.modelPath }}
    {{- $args = append $args (printf "--served-model-name %s" .Values.model) }}
{{- end }}
{{- if .Values.vllm.loadFormat }}
    {{- $args = append $args (printf "--load-format %s" .Values.vllm.loadFormat ) }}
{{- end}}
{{- if not (.Values.modelParameters | default dict).tensorParallelSize }}
    {{- $tpsize = (index .Values.inference.modelServer.deployment.resources.gpu.requests "nvidia.com/gpu")}}
    {{- $args = append $args (printf "--tensor-parallel-size %s" ($tpsize | toString) ) }}
{{- end}}
{{- printf "%s" (join " " $args) | trimSuffix " " -}}
{{- end -}}

{{/*
Select the modelServer resources block — всегда resources.gpu
(gpu — единственный поддерживаемый ускоритель).
*/}}
{{- define "inference-charts.acceleratorResources" -}}
{{- toYaml .Values.inference.modelServer.deployment.resources.gpu -}}
{{- end -}}

{{- define "inference-charts.s3ModelCopyName" -}}
{{- printf "s3modelcopy-%s" .Values.s3ModelCopy.model | lower | replace "/" "-" | replace "_" "-" | replace "." "-" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Extra labels from values.yaml applied to all resources
*/}}
{{- define "inference-charts.extraLabels" -}}
{{- with .Values.extraLabels }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Render CLI arguments for hf_s3_sync.py from s3ModelCopy.parameters map.
Boolean true  → --flag (present)
Boolean false → omitted
Other values  → --flag value
Keys are converted from camelCase to kebab-case.
*/}}
{{- define "inference-charts.s3ModelCopyParameters" -}}
{{- $args := list -}}
{{- range $key, $value := .Values.s3ModelCopy.parameters -}}
  {{- if kindIs "bool" $value -}}
    {{- if $value -}}
      {{- $args = append $args (printf "--%s" ($key | kebabcase)) -}}
    {{- end -}}
  {{- else -}}
    {{- $args = append $args (printf "--%s %v" ($key | kebabcase) $value) -}}
  {{- end -}}
{{- end -}}
{{- if .Values.s3ModelCopy.s3Prefix -}}
  {{- $args = append $args (printf "--prefix %s" .Values.s3ModelCopy.s3Prefix) -}}
{{- else -}}
  {{- $args = append $args (printf "--prefix %s" .Values.s3ModelCopy.model) -}}
{{- end -}}
{{- printf "%s" (join " " $args) | trimSuffix " " -}}
{{- end -}}

{{/*
Build the affinity block for the s3-copy Job.
When requireLocalDisk is true, adds nodeAffinity on the Selectel Karpenter
label karpenter.k8s.selectel/instance-local-disk=true (nodes with local disk).
Merges with any user-provided affinity.
*/}}
{{- define "inference-charts.s3ModelCopyAffinity" -}}
{{- $affinity := deepCopy (.Values.s3ModelCopy.affinity | default dict) -}}
{{- if .Values.s3ModelCopy.requireLocalDisk -}}
  {{- $existingNodeAffinity := index $affinity "nodeAffinity" | default dict -}}
  {{- $existingRequired := index $existingNodeAffinity "requiredDuringSchedulingIgnoredDuringExecution" | default dict -}}
  {{- $existingTerms := index $existingRequired "nodeSelectorTerms" | default list -}}
  {{- $term := dict "matchExpressions" (list (dict "key" "karpenter.k8s.selectel/instance-local-disk" "operator" "In" "values" (list "true"))) -}}
  {{- $_ := set $affinity "nodeAffinity" (dict "requiredDuringSchedulingIgnoredDuringExecution" (dict "nodeSelectorTerms" (append $existingTerms $term))) -}}
{{- end -}}
{{- if $affinity }}
affinity:
  {{- toYaml $affinity | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Render resources for the s3-copy Job container.
Merges s3ModelCopy.resources with ephemeral-storage derived from storageSize.
*/}}
{{- define "inference-charts.s3ModelCopyResources" -}}
{{- $resources := deepCopy (.Values.s3ModelCopy.resources | default dict) -}}
{{- if .Values.s3ModelCopy.storageSize -}}
  {{- $storage := printf "%dGi" (int .Values.s3ModelCopy.storageSize) -}}
  {{- $requests := index $resources "requests" | default dict -}}
  {{- $_ := set $requests "ephemeral-storage" $storage -}}
  {{- $_ := set $resources "requests" $requests -}}
  {{- $limits := index $resources "limits" | default dict -}}
  {{- $_ := set $limits "ephemeral-storage" $storage -}}
  {{- $_ := set $resources "limits" $limits -}}
{{- end -}}
{{- toYaml $resources -}}
{{- end -}}
