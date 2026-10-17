variable "aws_region" {
  description = "Região do laboratório. A mesma do ECR, de staging e de production."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "togglemaster"
}

variable "instance_type" {
  description = <<-EOT
    c7i-flex.large: 2 vCPU, 4 GiB. Está na lista de tipos do "free plan" da
    AWS (o mesmo dos nós do EKS) e dá conta do Backstage + Postgres.
  EOT
  type        = string
  default     = "c7i-flex.large"
}

variable "availability_zone" {
  description = "Uma AZ só: é uma máquina de laboratório, sem redundância."
  type        = string
  default     = "us-east-1a"
}

variable "vpc_cidr" {
  description = "VPC própria e pequena, fora das faixas dos ambientes (10.10, 10.20 e 10.30)."
  type        = string
  default     = "10.40.0.0/24"
}

variable "image_tag" {
  description = "Tag da imagem togglemaster/backstage no ECR (a esteira do repo toggle-master-backstage publica latest e <sha>)."
  type        = string
  default     = "latest"
}

variable "environments" {
  description = <<-EOT
    Ambientes que o Backstage procura a cada 2 minutos: nome => região. Os
    que não estiverem no ar são ignorados; quando um sobe, entra sozinho.
  EOT
  type        = map(string)
  default = {
    develop    = "us-east-2"
    staging    = "us-east-1"
    production = "us-east-1"
  }
}
