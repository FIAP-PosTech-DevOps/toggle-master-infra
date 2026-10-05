terraform {
  # 1.10+ é exigido por todos os stacks por causa do use_lockfile (lock
  # nativo do S3). Mantido igual aqui para o time usar uma versão só.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Sem bloco backend de propósito: state local (ver main.tf).
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
