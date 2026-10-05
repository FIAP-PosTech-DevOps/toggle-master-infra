variable "name" {
  description = "Nome da VPC (prefixo do projeto + ambiente)."
  type        = string
}

variable "cluster_name" {
  description = "Nome do cluster EKS — entra nas tags de descoberta das sub-redes."
  type        = string
}

variable "cidr" {
  description = "CIDR da VPC. Use faixas diferentes por ambiente para permitir peering no futuro."
  type        = string
}

variable "azs" {
  description = "Availability Zones. O EKS exige no mínimo 2."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "O EKS exige pelo menos 2 Availability Zones."
  }
}

variable "public_subnet_cidrs" {
  description = "Uma sub-rede pública por AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Uma sub-rede privada por AZ."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true = 1 NAT compartilhado; false = 1 por AZ."
  type        = bool
  default     = true
}
