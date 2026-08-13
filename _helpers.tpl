{{/*
==============================================================================
Actum Intelligence Platform — Helm template helpers
==============================================================================
Centralizes naming, labeling, and selector logic so every template
(deployment, service, hpa, pdb) derives identical, consistent metadata
instead of duplicating string logic across files.
*/}}

{{/*
Base chart name, honoring nameOverride.
*/}}
{{- define "actum-intelligence.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified release name, honoring fullnameOverride, and truncated to
fit the 63-character Kubernetes object-name / DNS-label limit.
*/}}
{{- define "actum-intelligence.fullname" -}}
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

{{/*
Chart name + version, used in the "helm.sh/chart" label.
*/}}
{{- define "actum-intelligence.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource in this chart.
*/}}
{{- define "actum-intelligence.labels" -}}
helm.sh/chart: {{ include "actum-intelligence.chart" . }}
{{ include "actum-intelligence.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels — the stable subset used for Deployment/Service/HPA
selectors. Must never change across chart versions without a migration
plan, since mutating selectors on an existing Deployment is immutable.
*/}}
{{- define "actum-intelligence.selectorLabels" -}}
app.kubernetes.io/name: {{ include "actum-intelligence.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Name of the ServiceAccount to use, honoring serviceAccount.create /
serviceAccount.name.
*/}}
{{- define "actum-intelligence.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "actum-intelligence.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
