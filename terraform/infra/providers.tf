provider "aws" {
  region = var.aws_region

  # default_tags aplica estas tags automaticamente a TODO recurso AWS deste
  # projeto, inclusive os criados dentro dos módulos. Por isso nenhum
  # recurso abaixo precisa repetir `tags = local.common_tags`.
  default_tags {
    tags = local.common_tags
  }
}
