# -----------------------------------------------------------------------------
# Backstage (laboratório): o que precisa existir SEMPRE, mesmo com o
# laboratório desligado
# -----------------------------------------------------------------------------
# O laboratório em si (VPC, EC2) fica no stack terraform/tooling e sobe só
# quando for usado. Aqui ficam as peças que outros stacks referenciam e que
# não custam nada paradas:
#
#   - repositório ECR da imagem do Backstage (a esteira do repo
#     toggle-master-backstage publica aqui);
#   - role IAM da EC2 do Backstage. Os clusters (stack infra) dão a ela acesso
#     de LEITURA via Access Entry, então ela precisa existir antes deles e não
#     pode sumir junto com o laboratório.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "backstage" {
  #checkov:skip=CKV_AWS_51:tag latest e reescrita a cada build do laboratorio; a tag <sha> continua unica
  name                 = "${var.project_name}/backstage"
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

# Laboratório: só as 5 imagens mais recentes (cada uma tem algumas centenas
# de MB).
resource "aws_ecr_lifecycle_policy" "backstage" {
  repository = aws_ecr_repository.backstage.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Manter so as 5 imagens mais recentes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# --- Role da EC2 do Backstage ------------------------------------------------

data "aws_iam_policy_document" "backstage_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backstage" {
  name               = "${var.project_name}-backstage"
  description        = "EC2 do laboratorio Backstage: le os clusters EKS (Access Entry de leitura) e puxa a imagem do ECR"
  assume_role_policy = data.aws_iam_policy_document.backstage_trust.json
}

# Session Manager: acesso à máquina e port-forward sem SSH e sem porta aberta.
resource "aws_iam_role_policy_attachment" "backstage_ssm" {
  role       = aws_iam_role.backstage.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "backstage_ecr" {
  role       = aws_iam_role.backstage.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "backstage" {
  # Descobrir quais clusters estão no ar e montar a configuração do plugin de
  # Kubernetes (endpoint + CA). O que ela pode fazer DENTRO do cluster é
  # decidido pela Access Entry (somente leitura), não por aqui.
  statement {
    sid       = "DescribeProjectClusters"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:*:${local.account_id}:cluster/${var.project_name}-*"]
  }

  # Segredos do laboratório (OAuth App e token do GitHub), criados à mão
  # como SecureString. A chave aws/ssm é gerenciada pela AWS: a decifragem
  # já é liberada para quem pode ler o parâmetro.
  statement {
    sid       = "ReadLabParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:${local.account_id}:parameter/${var.project_name}/backstage/*"]
  }
}

resource "aws_iam_role_policy" "backstage" {
  name   = "backstage-lab"
  role   = aws_iam_role.backstage.id
  policy = data.aws_iam_policy_document.backstage.json
}

resource "aws_iam_instance_profile" "backstage" {
  name = "${var.project_name}-backstage"
  role = aws_iam_role.backstage.name
}
