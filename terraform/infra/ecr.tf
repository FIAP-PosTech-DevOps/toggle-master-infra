resource "aws_ecr_repository" "this" {
  for_each = toset(var.services)

  name = "togglemaster/${each.key}"

  # IMMUTABLE = uma tag publicada nunca muda de conteúdo. É a boa prática
  # (o que rodou em produção continua reproduzível), mas significa que
  # `docker push ...:v1` uma segunda vez FALHA de propósito. Ao iterar,
  # suba v2, v3... ou use o short SHA do commit como tag.
  image_tag_mutability = "IMMUTABLE"

  # Sem isso, o `terraform destroy` falha com RepositoryNotEmptyException
  # assim que houver qualquer imagem publicada — e você precisa esvaziar os
  # repositórios na mão antes de conseguir derrubar o ambiente.
  #
  # Em produção force_delete = true é perigoso (apaga imagens que podem estar
  # rodando). Aqui é o comportamento correto: o laboratório é descartável e
  # as imagens são reconstruídas a cada ciclo pelo build-and-push.sh.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

# Imagens sem tag (camadas órfãs de builds antigos) são puro custo de
# storage — expira depois de 14 dias.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
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
        action = {
          type = "expire"
        }
      }
    ]
  })
}
