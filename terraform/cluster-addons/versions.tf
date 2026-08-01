terraform {
  required_version = ">= 1.6.0"

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

  # backend "s3" {
  #   bucket         = "togglemaster-tfstate-<seu-account-id>"
  #   key            = "cluster-addons/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "togglemaster-tfstate-lock"
  #   encrypt        = true
  # }
}
