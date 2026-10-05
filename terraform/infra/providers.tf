provider "aws" {
  region = var.aws_region

  # default_tags aplica estas tags a TODO recurso AWS do ambiente, inclusive
  # os criados dentro dos módulos. Nenhum recurso precisa repetir `tags`.
  default_tags {
    tags = local.common_tags
  }
}
