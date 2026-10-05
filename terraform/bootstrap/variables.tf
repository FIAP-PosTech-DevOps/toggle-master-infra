variable "aws_region" {
  description = "Região do bucket de state. Todos os stacks apontam o backend para esta região, mesmo os ambientes que rodam em outras."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo do nome do bucket (<project_name>-tfstate-<account_id>)."
  type        = string
  default     = "togglemaster"
}

variable "noncurrent_version_retention_days" {
  description = "Por quantos dias uma versão antiga do state fica disponível para restore."
  type        = number
  default     = 90
}
