variable "name_prefix" {
  type = string
}

variable "visibility_timeout_seconds" {
  type    = number
  default = 60
}

variable "max_receive_count" {
  description = "Tentativas de processamento antes da mensagem ir para a DLQ."
  type        = number
  default     = 5
}
