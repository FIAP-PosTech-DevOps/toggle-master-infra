# --- Geral -------------------------------------------------------------------

variable "aws_region" {
  description = "Região AWS onde a infra será provisionada."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos."
  type        = string
  default     = "togglemaster"
}

variable "environment" {
  description = "Nome do ambiente (entra no prefixo e nas tags)."
  type        = string
  default     = "lab"
}

variable "app_namespace" {
  description = "Namespace do Kubernetes onde os 5 microsserviços rodam. Precisa casar com o mesmo valor no módulo cluster-addons, porque entra na trust policy do IRSA."
  type        = string
  default     = "togglemaster"
}

variable "alert_email" {
  description = "E-mail que recebe os alertas de orçamento (50%, 80% e previsão de 100%)."
  type        = string
}

variable "services" {
  description = "Os 5 microsserviços — um repositório ECR para cada."
  type        = list(string)
  default = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]
}

# --- Rede --------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability Zones usadas. O EKS exige no mínimo 2."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Sub-redes públicas — só o Load Balancer vive aqui."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Sub-redes privadas — nós do EKS, RDS e ElastiCache."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "single_nat_gateway" {
  description = "true = 1 NAT Gateway compartilhado (economiza ~US$32/mês). false = 1 por AZ, mais resiliente."
  type        = bool
  default     = true
}

# --- EKS ---------------------------------------------------------------------

variable "cluster_version" {
  description = "Versão do Kubernetes no EKS."
  type        = string
  default     = "1.30"
}

variable "cluster_endpoint_public_access" {
  description = "Mantenha true para conseguir rodar kubectl da sua máquina."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Quem pode falar com o endpoint público do cluster. Troque pelo seu IP/32 (descubra com `curl ifconfig.me`)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = <<-EOT
    c7i-flex.large: 2 vCPU, 4 GiB, 29 pods por nó, amd64.
    Escolhido porque está na lista de tipos permitidos no "free plan" da AWS
    (contas criadas a partir de 15/07/2025 só podem usar t3.micro, t3.small,
    t4g.micro, t4g.small, c7i-flex.large ou m7i-flex.large — qualquer outro
    tipo falha com "not eligible for Free Tier").
    Dá folga de ~2x em pods e ~3x em memória sobre o pico da demo, o que
    dispensa Cluster Autoscaler: tudo cabe nos 2 nós estáticos.
  EOT
  type        = list(string)
  default     = ["c7i-flex.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND para um lab de janela curta: Spot economizaria centavos e traz risco de a AWS recuperar o nó no meio de um teste ou da gravação do vídeo."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "node_capacity_type deve ser SPOT ou ON_DEMAND."
  }
}

variable "node_min_size" {
  description = "Mínimo de nós no node group."
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Quantidade inicial de nós."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = <<-EOT
    Teto de nós. Atenção: não existe Cluster Autoscaler nem Karpenter nesta
    infra, então este valor é só uma autorização — ninguém cresce o node group
    automaticamente. Com c7i-flex.large os 2 nós de node_desired_size já
    absorvem o pico do HPA + KEDA, então isso não é um problema; serve como
    margem se você quiser subir desired_size manualmente.
  EOT
  type        = number
  default     = 4
}

# --- RDS ---------------------------------------------------------------------

variable "databases" {
  description = "Um RDS PostgreSQL por serviço: chave = sufixo do identifier, valor = nome do database."
  type        = map(string)
  default = {
    auth      = "auth_db"
    flag      = "flags_db"
    targeting = "targeting_db"
  }
}

variable "db_engine_version" {
  description = "Versão major do PostgreSQL."
  type        = string
  default     = "15"
}

variable "db_instance_class" {
  description = "Classe das instâncias RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Storage em GiB (mínimo 20 para gp3)."
  type        = number
  default     = 20
}

# --- ElastiCache -------------------------------------------------------------

variable "redis_node_type" {
  description = "Tipo do nó do Redis."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Versão do Redis."
  type        = string
  default     = "7.1"
}

# --- DynamoDB / SQS ----------------------------------------------------------

variable "dynamodb_table_name" {
  description = "Nome da tabela de analytics (precisa casar com AWS_DYNAMODB_TABLE no ConfigMap)."
  type        = string
  default     = "ToggleMasterAnalytics"
}

variable "sqs_max_receive_count" {
  description = "Tentativas de processamento antes da mensagem ir para a DLQ."
  type        = number
  default     = 5
}

# --- Orçamento ---------------------------------------------------------------

variable "budget_limit_usd" {
  description = "Teto mensal em USD para o alarme do AWS Budgets."
  type        = string
  default     = "80"
}
