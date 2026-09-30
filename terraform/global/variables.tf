# --- Geral -------------------------------------------------------------------

variable "aws_region" {
  description = "Região dos recursos compartilhados (ECR, KMS do ECR). Os ambientes puxam imagem daqui, mesmo rodando em outras regiões."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos."
  type        = string
  default     = "togglemaster"
}

variable "services" {
  description = "Os 5 microsserviços — um repositório ECR e um repositório GitHub para cada."
  type        = list(string)
  default = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]
}

# --- ECR ---------------------------------------------------------------------

variable "mirror_repositories" {
  description = <<-EOT
    Repositórios de espelho para imagens de terceiros cujo upstream exigiria
    credencial no pull-through cache (ghcr.io e Docker Hub). São populados por
    k8s/mirror-images.sh; aqui eles só passam a existir "no código".
  EOT
  type        = list(string)
  default = [
    "mirror/kedacore/keda",
    "mirror/kedacore/keda-metrics-apiserver",
    "mirror/kedacore/keda-admission-webhooks",
    "mirror/library/golang",
    "mirror/library/alpine",
    "mirror/library/python",
    "mirror/library/postgres",
    "mirror/library/redis",
  ]
}

variable "ecr_keep_tagged_images" {
  description = "Quantas imagens com tag cada repositório mantém. As mais antigas expiram."
  type        = number
  default     = 50
}

# --- GitHub Actions (OIDC) ---------------------------------------------------

variable "github_org" {
  description = "Organização (ou usuário) dono dos repositórios no GitHub."
  type        = string
  default     = "FIAP-PosTech-DevOps"
}

variable "infra_repository" {
  description = "Repositório que contém este Terraform. Só ele pode assumir as roles de plan/apply."
  type        = string
  default     = "toggle-master-infra"
}

variable "ci_push_refs" {
  description = <<-EOT
    Refs Git dos serviços que podem publicar imagem no ECR (padrão
    StringLike). Estratégia de branches do projeto: as demandas entram por PR
    numa release/vX.Y.Z; cada push na release gera imagem e sobe em develop.
    As tags vX.Y.Z-rc.N (staging) e vX.Y.Z (production) só promovem a imagem
    já publicada, mas também podem consultar o ECR. PRs e feature/* rodam a
    pipeline sem publicar nada.
  EOT
  type        = list(string)
  default     = ["refs/heads/release/*", "refs/tags/v*"]
}

variable "deploy_environments" {
  description = "GitHub Environments do repositório de infra que podem assumir a role de apply. Cada um deve ter regra de proteção configurada no GitHub."
  type        = list(string)
  default     = ["develop", "staging", "production"]
}

# --- Orçamento ---------------------------------------------------------------

variable "alert_email" {
  description = "E-mail que recebe os alertas de orçamento (50%, 80% e previsão de 100%)."
  type        = string
}

variable "budget_limit_usd" {
  description = "Teto mensal em USD da CONTA inteira (os 3 ambientes somados)."
  type        = string
  default     = "100"
}
