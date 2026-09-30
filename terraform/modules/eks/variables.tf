variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  description = "Versão do Kubernetes. Use uma versão em standard support: extended support custa US$0,60/h em vez de US$0,10/h."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Sub-redes privadas onde ficam os nós."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK do ambiente, usada para criptografar os Secrets do etcd."
  type        = string
}

variable "endpoint_public_access" {
  type    = bool
  default = true
}

variable "endpoint_public_access_cidrs" {
  description = "Quem pode falar com o endpoint público do cluster."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arns" {
  description = "ARNs (usuários ou roles IAM) que recebem cluster-admin via Access Entry."
  type        = list(string)
}

variable "node_instance_types" {
  type = list(string)
}

variable "node_capacity_type" {
  type = string

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "node_capacity_type deve ser SPOT ou ON_DEMAND."
  }
}

variable "node_min_size" {
  type = number
}

variable "node_desired_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "node_additional_policy_arns" {
  description = "Policies extras para a role dos nós (ex.: pull-through cache do ECR)."
  type        = map(string)
  default     = {}
}
