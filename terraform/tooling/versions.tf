terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Backend parcial: key tooling/terraform.tfstate em backend.s3.tfbackend; o
  # bucket é injetado pelo tf.sh. State próprio: subir ou destruir o
  # laboratório nunca toca o state dos ambientes.
  backend "s3" {}
}
