terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Backend remoto (opcional). Por padrão o state fica local, num arquivo
  # terraform.tfstate nesta pasta — suficiente para um laboratório
  # individual. Se o grupo do desafio for aplicar a mesma infra, veja
  # backend.tf.example para criar o bucket S3 + tabela de lock e depois
  # descomente o bloco abaixo.
  #
  # backend "s3" {
  #   bucket         = "togglemaster-tfstate-<seu-account-id>"
  #   key            = "infra/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "togglemaster-tfstate-lock"
  #   encrypt        = true
  # }
}
