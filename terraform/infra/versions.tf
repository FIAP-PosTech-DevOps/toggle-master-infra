terraform {
  # 1.10+ por causa do use_lockfile (lock nativo do S3).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Backend parcial: a key (infra/<ambiente>/terraform.tfstate) e a região
  # vêm de envs/<ambiente>.s3.tfbackend, e o bucket é injetado pelo tf.sh.
  # Um state por ambiente: um apply em develop nunca toca o state de
  # production.
  backend "s3" {}
}
