variable "name_prefix" {
  description = "<projeto>-<ambiente>, prefixo de todos os nomes."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Sub-redes privadas."
  type        = list(string)
}

variable "client_security_group_id" {
  description = "SG autorizado a falar com RDS e Redis (o SG dos nós do EKS)."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK do ambiente para criptografia em repouso."
  type        = string
}

variable "deletion_protection" {
  description = "Liga deletion protection no RDS/DynamoDB e snapshot final no destroy."
  type        = bool
  default     = false
}

# --- RDS ---------------------------------------------------------------------

variable "databases" {
  description = "Um RDS por serviço: chave = sufixo do identifier, valor = nome do database."
  type        = map(string)
}

variable "db_engine_version" {
  type = string
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage" {
  type = number
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 1
}

# --- ElastiCache -------------------------------------------------------------

variable "redis_node_type" {
  type = string
}

variable "redis_engine_version" {
  type = string
}

# --- DynamoDB ----------------------------------------------------------------

variable "dynamodb_table_name" {
  description = "Nome da tabela (o desafio exige ToggleMasterAnalytics). Tabelas são regionais, então o mesmo nome pode existir em cada ambiente."
  type        = string
}

variable "dynamodb_point_in_time_recovery" {
  type    = bool
  default = false
}
