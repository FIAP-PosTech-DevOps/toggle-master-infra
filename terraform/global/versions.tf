terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Backend parcial: bucket, key e região vêm de backend.s3.tfbackend + do
  # tf.sh (que injeta o nome do bucket pelo account ID). Assim nenhum arquivo
  # versionado precisa conter o número da conta.
  backend "s3" {}
}
