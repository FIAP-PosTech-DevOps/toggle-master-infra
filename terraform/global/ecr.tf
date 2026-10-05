# -----------------------------------------------------------------------------
# ECR compartilhado pelos 3 ambientes
# -----------------------------------------------------------------------------
# Um único registry (nesta região) para develop, staging e production. É o que
# permite "promover" a MESMA imagem entre ambientes: a CI faz o build uma vez,
# publica v1.0.0-<sha>, e cada ambiente só troca a tag no repositório GitOps.
# Rebuild por ambiente geraria binários diferentes para o que deveria ser a
# mesma versão.
#
# Os clusters em outras regiões puxam daqui (cross-region). O custo de
# transferência é de centavos para o volume deste projeto.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "ecr" {
  description             = "${var.project_name} - criptografia das imagens no ECR"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.ecr_key.json
}

# Policy explícita (igual à padrão da AWS): a conta administra a chave e o
# acesso de cada serviço/role é concedido por IAM. Deixar implícito funciona,
# mas esconde de quem lê o código quem pode usar a chave.
data "aws_iam_policy_document" "ecr_key" {
  # Key policy: "Resource = *" aqui significa "esta chave" (padrão da AWS).
  #checkov:skip=CKV_AWS_109:key policy padrao da conta
  #checkov:skip=CKV_AWS_111:key policy padrao da conta
  #checkov:skip=CKV_AWS_356:key policy padrao da conta
  statement {
    sid       = "EnableAccountIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.project_name}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

resource "aws_ecr_repository" "services" {
  for_each = toset(var.services)

  name = "${var.project_name}/${each.key}"

  # IMMUTABLE: uma tag publicada nunca muda de conteúdo. O que rodou em
  # produção continua reproduzível. A CI usa v1.0.0-<sha>, única por commit.
  image_tag_mutability = "IMMUTABLE"

  # Laboratório descartável: sem isso o destroy falha com
  # RepositoryNotEmptyException. Em produção real seria false.
  force_delete = true

  # Scan nativo do ECR, além do Trivy que roda na pipeline antes do push.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expirar imagens sem tag apos 14 dias"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Manter apenas as ${var.ecr_keep_tagged_images} imagens com tag mais recentes"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.ecr_keep_tagged_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Espelhos de imagens de terceiros. MUTABLE de propósito: espelho é cópia de
# upstream, e reespelhar a mesma tag num novo ciclo é o normal.
resource "aws_ecr_repository" "mirror" {
  for_each = toset(var.mirror_repositories)

  #checkov:skip=CKV_AWS_51:espelho de upstream; reespelhar a mesma tag e o comportamento esperado
  name                 = each.key
  image_tag_mutability = "MUTABLE" #trivy:ignore:AVD-AWS-0031
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

# -----------------------------------------------------------------------------
# Pull-through cache (registros públicos que não exigem credencial)
# -----------------------------------------------------------------------------
# Todo pull passa pelo ECR privado: imune a rate limit, sem dependência do
# upstream em runtime, e com o scan do ECR sobre imagens de terceiros.

# registry.k8s.io -> metrics-server e ingress-nginx
resource "aws_ecr_pull_through_cache_rule" "k8s" {
  ecr_repository_prefix = "k8s"
  upstream_registry_url = "registry.k8s.io"
}

# public.ecr.aws -> aws-load-balancer-controller
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}
