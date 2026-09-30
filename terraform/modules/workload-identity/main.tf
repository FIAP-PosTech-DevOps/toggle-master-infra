# -----------------------------------------------------------------------------
# IRSA (IAM Roles for Service Accounts) dos workloads de um ambiente
# -----------------------------------------------------------------------------
# Cada workload que fala com a AWS assume a SUA role, via token OIDC montado
# no pod. Nenhuma AWS_ACCESS_KEY_ID/SECRET em manifesto, e a role do nó fica
# sem permissão de SQS/DynamoDB/ELB/KMS.
#
# Todas as trust policies usam o módulo oficial iam-role-for-service-accounts
# -eks: o `sub` precisa casar exatamente com namespace:serviceaccount, e errar
# isso gera um AccessDenied difícil de depurar.
#
# Mudança da Fase 3: cada microsserviço tem o seu namespace (sugestão da
# correção da Fase 2), então o namespace entra na trust de cada role.
# -----------------------------------------------------------------------------

# --- AWS Load Balancer Controller -------------------------------------------
module "irsa_alb_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${var.name_prefix}-irsa-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [var.service_accounts.alb_controller]
    }
  }
}

# --- evaluation-service: só publica na fila ---------------------------------
data "aws_iam_policy_document" "evaluation" {
  statement {
    sid       = "SendEvaluationEvents"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [var.sqs_queue_arn]
  }
}

resource "aws_iam_policy" "evaluation" {
  name   = "${var.name_prefix}-evaluation"
  policy = data.aws_iam_policy_document.evaluation.json
}

module "irsa_evaluation" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.name_prefix}-irsa-evaluation"

  role_policy_arns = {
    evaluation = aws_iam_policy.evaluation.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [var.service_accounts.evaluation]
    }
  }
}

# --- analytics-service: consome a fila e grava no DynamoDB ------------------
data "aws_iam_policy_document" "analytics" {
  statement {
    sid    = "ConsumeAnalyticsQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.sqs_queue_arn]
  }

  statement {
    sid       = "WriteAnalyticsTable"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [var.dynamodb_table_arn]
  }
}

resource "aws_iam_policy" "analytics" {
  name   = "${var.name_prefix}-analytics"
  policy = data.aws_iam_policy_document.analytics.json
}

module "irsa_analytics" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.name_prefix}-irsa-analytics"

  role_policy_arns = {
    analytics = aws_iam_policy.analytics.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [var.service_accounts.analytics]
    }
  }
}

# --- KEDA: só precisa ler o tamanho da fila ---------------------------------
# Quem chama o SQS para decidir escalar é o POD DO OPERADOR do KEDA, não o
# analytics-service. Por isso a trust aponta para keda:keda-operator.
data "aws_iam_policy_document" "keda" {
  statement {
    sid    = "ReadQueueDepth"
    effect = "Allow"
    actions = [
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [var.sqs_queue_arn]
  }
}

resource "aws_iam_policy" "keda" {
  name   = "${var.name_prefix}-keda"
  policy = data.aws_iam_policy_document.keda.json
}

module "irsa_keda" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.name_prefix}-irsa-keda"

  role_policy_arns = {
    keda = aws_iam_policy.keda.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [var.service_accounts.keda]
    }
  }
}

# --- OpenBao: auto-unseal com AWS KMS ---------------------------------------
# Sem auto-unseal, todo restart do pod do OpenBao deixaria o cofre "selado"
# até alguém digitar as chaves de unseal à mão. Com o seal "awskms", a chave
# mestra do OpenBao é cifrada por esta CMK, e o pod se desbloqueia sozinho —
# desde que a SA dele tenha permissão nesta chave, e só nela.
resource "aws_kms_key" "openbao_unseal" {
  description             = "${var.name_prefix} - auto-unseal do OpenBao"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.openbao_unseal_key.json
}

# Policy explícita (igual à padrão da AWS): a conta administra a chave e o
# acesso de cada serviço/role é concedido por IAM. Deixar implícito funciona,
# mas esconde de quem lê o código quem pode usar a chave.
data "aws_iam_policy_document" "openbao_unseal_key" {
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
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_alias" "openbao_unseal" {
  # O cluster-addons referencia a chave por este alias, sem precisar ler o
  # state deste stack.
  name          = "alias/${var.name_prefix}-openbao-unseal"
  target_key_id = aws_kms_key.openbao_unseal.key_id
}

data "aws_iam_policy_document" "openbao" {
  statement {
    sid    = "AutoUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.openbao_unseal.arn]
  }
}

resource "aws_iam_policy" "openbao" {
  name   = "${var.name_prefix}-openbao-unseal"
  policy = data.aws_iam_policy_document.openbao.json
}

module "irsa_openbao" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.name_prefix}-irsa-openbao"

  role_policy_arns = {
    openbao = aws_iam_policy.openbao.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = [var.service_accounts.openbao]
    }
  }
}

data "aws_caller_identity" "current" {}
