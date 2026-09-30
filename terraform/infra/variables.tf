# Os valores de cada ambiente ficam em envs/<ambiente>.tfvars. Os defaults
# abaixo são os comuns aos três.

# --- Geral -------------------------------------------------------------------

variable "environment" {
  description = "Nome do ambiente. Entra no prefixo de todos os recursos e nas tags."
  type        = string

  validation {
    condition     = contains(["develop", "staging", "production"], var.environment)
    error_message = "environment deve ser develop, staging ou production."
  }
}

variable "aws_region" {
  description = "Região do ambiente. Cada ambiente fica numa região diferente."
  type        = string
}

variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos."
  type        = string
  default     = "togglemaster"
}

variable "deletion_protection" {
  description = "Liga deletion protection no RDS/DynamoDB. Deixe false em ambientes descartáveis."
  type        = bool
  default     = false
}

# --- Acesso ao cluster -------------------------------------------------------

variable "cluster_admin_principal_arns" {
  description = <<-EOT
    ARNs de usuários/roles IAM (além das roles do GitHub Actions) que recebem
    cluster-admin. Coloque o SEU: descubra com
      aws sts get-caller-identity --query Arn --output text
    Se o resultado for um assumed-role, use o ARN da role
    (arn:aws:iam::<conta>:role/<nome>), não o da sessão.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = length(var.cluster_admin_principal_arns) > 0 && alltrue([
      for arn in var.cluster_admin_principal_arns :
      can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", arn))
    ])
    error_message = "Preencha cluster_admin_principal_arns em envs/<ambiente>.tfvars com o ARN do seu usuário ou role IAM (arn:aws:iam::<conta>:user/<nome>). Sem isso ninguém além da CI teria kubectl no cluster."
  }
}

variable "ci_role_names" {
  description = "Roles do GitHub Actions criadas pelo stack global que recebem acesso ao cluster."
  type        = list(string)
  default = [
    "togglemaster-gha-terraform-plan",
    "togglemaster-gha-terraform-apply",
  ]
}

# --- ECR (stack global) ------------------------------------------------------

variable "ecr_region" {
  description = "Região do registry compartilhado criado pelo stack global."
  type        = string
  default     = "us-east-1"
}

variable "ecr_pull_through_prefixes" {
  description = "Prefixos de pull-through cache criados no stack global."
  type        = list(string)
  default     = ["k8s", "ecr-public"]
}

# --- Rede --------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR da VPC. Faixas diferentes por ambiente (10.10/16, 10.20/16, 10.30/16)."
  type        = string
}

variable "azs" {
  description = "Availability Zones da região do ambiente (mínimo 2)."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Sub-redes públicas — só o Load Balancer e o NAT vivem aqui."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Sub-redes privadas — nós do EKS, RDS e ElastiCache."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true = 1 NAT Gateway compartilhado (economiza ~US$32/mês por AZ)."
  type        = bool
  default     = true
}

# --- EKS ---------------------------------------------------------------------

variable "cluster_version" {
  description = "Versão do Kubernetes. Confira as versões em standard support com: aws eks describe-cluster-versions --output table"
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access" {
  description = "true para rodar kubectl da sua máquina e do GitHub Actions."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Quem pode falar com o endpoint público do cluster."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = <<-EOT
    c7i-flex.large: 2 vCPU, 4 GiB, amd64. Está na lista de tipos permitidos
    no "free plan" da AWS (contas criadas a partir de 15/07/2025 só podem usar
    t3/t4g micro/small, c7i-flex.large ou m7i-flex.large).
  EOT
  type        = list(string)
  default     = ["c7i-flex.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND evita que a AWS recupere o nó no meio da gravação do vídeo."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  description = "2 nós absorvem o pico do HPA + KEDA + ArgoCD + OpenBao deste projeto."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Teto de nós. Não há Cluster Autoscaler: é só uma autorização para subir desired_size à mão."
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
  type    = string
  default = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Storage em GiB (mínimo 20 para gp3)."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Multi-AZ dobra o custo de cada uma das 3 instâncias."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 1
}

# --- ElastiCache -------------------------------------------------------------

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

# --- DynamoDB / SQS ----------------------------------------------------------

variable "dynamodb_table_name" {
  description = "Nome exigido pelo desafio. Precisa casar com AWS_DYNAMODB_TABLE no repositório GitOps."
  type        = string
  default     = "ToggleMasterAnalytics"
}

variable "dynamodb_point_in_time_recovery" {
  type    = bool
  default = false
}

variable "sqs_max_receive_count" {
  description = "Tentativas de processamento antes da mensagem ir para a DLQ."
  type        = number
  default     = 5
}
