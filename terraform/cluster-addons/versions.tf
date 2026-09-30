terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }

  # Backend parcial: key cluster-addons/<ambiente>/terraform.tfstate em
  # envs/<ambiente>.s3.tfbackend; o bucket é injetado pelo tf.sh.
  backend "s3" {}
}
