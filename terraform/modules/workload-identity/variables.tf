variable "name_prefix" {
  description = "<projeto>-<ambiente>. Entra no nome das roles — nomes de IAM são globais na conta, então o ambiente precisa estar nele."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Provedor OIDC do cluster (saída do módulo eks)."
  type        = string
}

variable "sqs_queue_arn" {
  type = string
}

variable "dynamodb_table_arn" {
  type = string
}

variable "service_accounts" {
  description = <<-EOT
    namespace:serviceaccount de cada workload. Precisa casar com os
    manifestos do repositório GitOps (evaluation, analytics) e com os
    helm_release do cluster-addons (alb_controller, keda, openbao).
  EOT
  type = object({
    alb_controller = string
    evaluation     = string
    analytics      = string
    keda           = string
    openbao        = string
  })
  default = {
    alb_controller = "kube-system:aws-load-balancer-controller"
    evaluation     = "evaluation-service:evaluation-service-sa"
    analytics      = "analytics-service:analytics-service-sa"
    keda           = "keda:keda-operator"
    openbao        = "openbao:openbao"
  }
}
