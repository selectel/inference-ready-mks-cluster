{{- define "ai-ml-observability.opensearchPassword" -}}
{{- required "opensearch.credentials.adminPassword is required when OpenSearch is enabled" .Values.opensearch.credentials.adminPassword -}}
{{- end -}}

{{- define "ai-ml-observability.opensearchDashboardPassword" -}}
{{- required "opensearch.credentials.dashboardUserPassword is required when OpenSearch is enabled" .Values.opensearch.credentials.dashboardUserPassword -}}
{{- end -}}
