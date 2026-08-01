# Este módulo NÃO pede vpc_id nem os ARNs das roles IRSA: ele descobre tudo
# a partir do cluster e da convenção de nomes do módulo infra. Se você não
# mudou project_name/environment lá, não precisa de nenhum tfvars aqui —
# exceto, possivelmente, as versões dos charts (veja abaixo).

variable "aws_region" {
  description = "Precisa ser a mesma região do módulo infra."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Mesmo valor usado no módulo infra."
  type        = string
  default     = "togglemaster"
}

variable "environment" {
  description = "Mesmo valor usado no módulo infra."
  type        = string
  default     = "lab"
}

variable "app_namespace" {
  description = "Mesmo valor usado no módulo infra (entra na trust policy do IRSA)."
  type        = string
  default     = "togglemaster"
}

# --- Versões dos Helm charts -------------------------------------------------
#
# Fixar versão é boa prática: garante que um novo apply amanhã instale
# exatamente o que você testou hoje, em vez de puxar um "latest" que mudou.
#
# Mas os defaults abaixo podem estar defasados em relação ao seu cluster.
# Descubra as versões corretas rodando:
#
#     ./check-chart-versions.sh 1.36
#
# O script mostra a última versão de cada chart e a restrição kubeVersion que
# ele declara. Se algum default aqui não suportar o seu Kubernetes, sobrescreva
# no terraform.tfvars.

variable "metrics_server_chart_version" {
  description = "Versão do chart metrics-server. Confirme com ./check-chart-versions.sh"
  type        = string
  default     = "3.12.2"
}

variable "alb_controller_chart_version" {
  description = "Versão do chart aws-load-balancer-controller. Confirme com ./check-chart-versions.sh"
  type        = string
  default     = "1.8.1"
}

variable "ingress_nginx_chart_version" {
  description = "Versão do chart ingress-nginx. Confirme com ./check-chart-versions.sh"
  type        = string
  default     = "4.11.2"
}

variable "keda_chart_version" {
  description = "Versão do chart KEDA. Confirme com ./check-chart-versions.sh"
  type        = string
  default     = "2.15.1"
}
