{{/*
Expand the name of the chart.
*/}}
{{- define "multica.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "multica.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "multica.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "multica.labels" -}}
helm.sh/chart: {{ include "multica.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Backend selector labels.
*/}}
{{- define "multica.backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "multica.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backend
{{- end -}}

{{/*
Frontend selector labels.
*/}}
{{- define "multica.frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "multica.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end -}}

{{/*
Create the name of the service account to use.
*/}}
{{- define "multica.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "multica.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Backend service name.
The published frontend image has REMOTE_API_URL=http://backend:8080 baked in
at build time. The backend Service must therefore be reachable as "backend"
within the namespace by default.
*/}}
{{- define "multica.backend.serviceName" -}}
{{- default "backend" .Values.backend.service.nameOverride -}}
{{- end -}}

{{/*
Frontend service name.
*/}}
{{- define "multica.frontend.serviceName" -}}
{{- printf "%s-frontend" (include "multica.fullname" .) -}}
{{- end -}}

{{/*
Backend secret name.
*/}}
{{- define "multica.secretName" -}}
{{- if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "multica.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Backend PVC name.
*/}}
{{- define "multica.pvcName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-uploads" (include "multica.fullname" .) -}}
{{- end -}}
{{- end -}}
