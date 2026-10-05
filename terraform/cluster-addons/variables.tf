# Este stack NÃO pede vpc_id nem ARNs de role: descobre tudo a partir do
# cluster e da convenção de nomes do stack infra. Os valores de cada ambiente
# ficam em envs/<ambiente>.tfvars.

variable "environment" {
  description = "Mesmo valor usado no stack infra."
  type        = string

  validation {
    condition     = contains(["develop", "staging", "production"], var.environment)
    error_message = "environment deve ser develop, staging ou production."
  }
}

variable "aws_region" {
  description = "Região do ambiente (mesma do stack infra)."
  type        = string
}

variable "ecr_region" {
  description = "Região do registry compartilhado (stack global)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "togglemaster"
}

# --- GitOps ------------------------------------------------------------------

variable "gitops_repo_url" {
  description = "Repositório com os manifestos que o ArgoCD sincroniza."
  type        = string
  default     = "https://github.com/FIAP-PosTech-DevOps/toggle-master-gitops.git"
}

variable "gitops_target_revision" {
  description = "Branch do repositório GitOps. Um branch só; o ambiente é escolhido pela pasta (clusters/<ambiente>)."
  type        = string
  default     = "main"
}

variable "argocd_reconciliation_timeout" {
  description = "De quanto em quanto tempo o ArgoCD consulta o repositório GitOps. O padrão do chart é 120s; 60s deixa a demo mais rápida sem precisar de webhook."
  type        = string
  default     = "60s"
}

# --- OpenBao -----------------------------------------------------------------

variable "openbao_storage_size" {
  description = "Tamanho do volume EBS com os dados do OpenBao."
  type        = string
  default     = "2Gi"
}

# --- Versões dos Helm charts -------------------------------------------------
#
# Fixar versão garante que um apply amanhã instale o mesmo que foi testado
# hoje. Confira se continuam compatíveis com o seu Kubernetes com:
#
#     ./check-chart-versions.sh 1.36

variable "metrics_server_chart_version" {
  type    = string
  default = "3.13.1"
}

variable "alb_controller_chart_version" {
  type    = string
  default = "3.4.3"
}

variable "ingress_nginx_chart_version" {
  type    = string
  default = "4.15.1"
}

variable "keda_chart_version" {
  description = "A versão do chart também é a tag das imagens espelhadas por k8s/mirror-images.sh."
  type        = string
  default     = "2.20.1"
}

variable "argocd_chart_version" {
  description = "Chart argo-cd (argoproj/argo-helm)."
  type        = string
  default     = "10.9.4"
}

variable "argocd_apps_chart_version" {
  description = "Chart argocd-apps, usado para criar a Application raiz (app-of-apps)."
  type        = string
  default     = "2.0.6"
}

variable "openbao_chart_version" {
  description = "Chart openbao (openbao/openbao-helm)."
  type        = string
  default     = "0.30.0"
}

variable "external_secrets_chart_version" {
  description = "Chart external-secrets."
  type        = string
  default     = "2.11.0"
}
