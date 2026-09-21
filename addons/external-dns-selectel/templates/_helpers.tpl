{{/* Ленивый fullname: имя фиксировано и совпадает с ожиданиями вебхука. */}}
{{- define "external-dns-selectel.fullname" -}}
{{- printf "%s-%s" .Release.Name "selectel" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
