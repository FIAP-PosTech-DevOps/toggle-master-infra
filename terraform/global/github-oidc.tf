# -----------------------------------------------------------------------------
# GitHub Actions -> AWS sem chave de acesso (OIDC)
# -----------------------------------------------------------------------------
# Nenhum AWS_ACCESS_KEY_ID/SECRET fica guardado no GitHub. A cada job, o
# GitHub emite um token OIDC de curta duração, e a AWS o troca por credenciais
# temporárias de uma role — desde que o `sub` do token (repositório + branch
# ou environment) case com a trust policy abaixo.
#
# Formato do `sub`: repositórios criados a partir de 15/07/2026 (todos os
# deste projeto) recebem o formato IMUTÁVEL, com os IDs numéricos do dono e
# do repositório:
#
#   repo:FIAP-PosTech-DevOps@<owner_id>/toggle-master-infra@<repo_id>:pull_request
#
# O ID não muda se alguém apagar a organização e outra pessoa recriar uma com
# o mesmo nome: a trust policy deixa de confiar só no nome. Os IDs estão em
# variables.tf (github_owner_id e github_repository_ids).
#
# Três roles, cada uma com o mínimo que o job precisa:
#
#   gha-ecr-push         repos dos serviços, só em release/* e tags v*
#   gha-terraform-plan   repo de infra, qualquer branch/PR, somente leitura
#   gha-terraform-apply  repo de infra, só via GitHub Environment (com
#                        aprovação configurável no GitHub), admin
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  oidc_host  = "token.actions.githubusercontent.com"

  # Prefixo imutável de cada repositório: repo:<org>@<owner_id>/<repo>@<repo_id>
  repo_subject = {
    for repo, id in var.github_repository_ids :
    repo => "repo:${var.github_org}@${var.github_owner_id}/${repo}@${id}"
  }

  # <prefixo>:ref:<ref>, para cada serviço x ref permitida
  # (ex.: repo:FIAP-PosTech-DevOps@286820110/auth-service@1312425511:ref:refs/heads/release/*).
  ecr_push_subjects = flatten([
    for repo in var.services : [
      for ref in var.ci_push_refs :
      "${local.repo_subject[repo]}:ref:${ref}"
    ]
  ])

  # Jobs que declaram `environment:` recebem um sub com o environment no lugar
  # da branch: <prefixo>:environment:<nome>.
  apply_subjects = [
    for env in var.deploy_environments :
    "${local.repo_subject[var.infra_repository]}:environment:${env}"
  ]

  # Qualquer branch, tag ou PR do repositório de infra (role somente leitura).
  plan_subject = "${local.repo_subject[var.infra_repository]}:*"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]

  # A AWS não valida mais o thumbprint para o GitHub (usa a própria CA), mas o
  # provider 5.x ainda pede a lista. São os valores publicados pelo GitHub.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# --- Trust policies ----------------------------------------------------------

data "aws_iam_policy_document" "trust_ecr_push" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike por causa dos curingas (release/*, v*).
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = local.ecr_push_subjects
    }
  }
}

data "aws_iam_policy_document" "trust_terraform_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Qualquer branch ou PR do repositório de infra. A role é somente leitura.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = [local.plan_subject]
    }
  }
}

data "aws_iam_policy_document" "trust_terraform_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = local.apply_subjects
    }
  }
}

# --- Role: publicar imagem no ECR --------------------------------------------

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushServiceImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.services : r.arn]
  }
}

resource "aws_iam_role" "gha_ecr_push" {
  name               = "${var.project_name}-gha-ecr-push"
  description        = "GitHub Actions dos microsservicos: publica imagem no ECR"
  assume_role_policy = data.aws_iam_policy_document.trust_ecr_push.json

  # Sessão curta: um build + push não passa de alguns minutos.
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gha_ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.gha_ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# --- Role: terraform plan (somente leitura) ----------------------------------

data "aws_iam_policy_document" "terraform_state" {
  # O plan também grava/remove o arquivo de lock (<key>.tflock) no bucket.
  statement {
    sid    = "StateBucketList"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = ["arn:aws:s3:::${var.project_name}-tfstate-${local.account_id}"]
  }

  statement {
    sid    = "StateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${var.project_name}-tfstate-${local.account_id}/*"]
  }
}

resource "aws_iam_role" "gha_terraform_plan" {
  name                 = "${var.project_name}-gha-terraform-plan"
  description          = "GitHub Actions do repo de infra: terraform plan (leitura)"
  assume_role_policy   = data.aws_iam_policy_document.trust_terraform_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gha_terraform_plan_readonly" {
  role       = aws_iam_role.gha_terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "gha_terraform_plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.gha_terraform_plan.id
  policy = data.aws_iam_policy_document.terraform_state.json
}

# --- Role: terraform apply ---------------------------------------------------
# AdministratorAccess porque o apply cria VPC, EKS, IAM, KMS, RDS... Escopar
# tudo isso item a item seria uma policy enorme e frágil. A proteção está na
# trust policy: só jobs com `environment:` do repo de infra assumem esta role,
# e o GitHub Environment "production" pode exigir aprovação manual.
resource "aws_iam_role" "gha_terraform_apply" {
  name                 = "${var.project_name}-gha-terraform-apply"
  description          = "GitHub Actions do repo de infra: terraform apply via Environment"
  assume_role_policy   = data.aws_iam_policy_document.trust_terraform_apply.json
  max_session_duration = 7200 # criar um EKS do zero leva ~20 min; destroy também
}

resource "aws_iam_role_policy_attachment" "gha_terraform_apply_admin" {
  #checkov:skip=CKV_AWS_274:apply cria IAM/VPC/EKS/RDS; protecao esta na trust (so GitHub Environments do repo de infra)
  role       = aws_iam_role.gha_terraform_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
