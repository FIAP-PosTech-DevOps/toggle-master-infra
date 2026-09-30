# -----------------------------------------------------------------------------
# Bootstrap do backend remoto
# -----------------------------------------------------------------------------
# Este é o ÚNICO stack com state local. Ele cria o bucket S3 onde todos os
# outros stacks (global, infra/<env>, cluster-addons/<env>) guardam o state.
#
# Por que state local aqui: é o problema do ovo e da galinha — o bucket ainda
# não existe quando este stack roda pela primeira vez. Como ele só contém o
# bucket, recriar este state é trivial (terraform import), e o bucket tem
# prevent_destroy para não ser apagado por engano.
#
# Versionamento do state (anotação "manter e versionar o tfstate"):
#   - versioning = Enabled: cada `apply` gera uma nova versão do objeto. Um
#     state corrompido ou apagado volta com um "restore" de versão anterior,
#     sem precisar de cópia manual de backup.
#   - lifecycle: versões antigas ficam 90 dias (as 30 mais recentes sempre
#     ficam), e só depois expiram. Evita custo infinito de storage.
#
# Lock: os stacks usam `use_lockfile = true` (lock nativo do S3, Terraform
# >= 1.10). Ele grava um objeto <key>.tflock no próprio bucket enquanto um
# plan/apply roda. A tabela DynamoDB de lock ficou obsoleta a partir do
# Terraform 1.11 — por isso não é criada aqui.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # O account ID no nome garante unicidade global (nomes de bucket são
  # globais em toda a AWS) sem precisar inventar sufixo aleatório.
  bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # Um `terraform destroy` neste stack apagaria o state de TODOS os ambientes.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    # Bucket key reduz as chamadas ao KMS (e o custo) em até 99%.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # O lifecycle precisa do versionamento já ativo, senão a primeira aplicação
  # pode falhar por corrida entre as duas chamadas de API.
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expirar-versoes-antigas-do-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_retention_days
      newer_noncurrent_versions = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Recusa qualquer acesso sem TLS: o state tem endpoints, ARNs e, em alguns
# recursos, valores sensíveis.
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
