# IRSA (IAM Roles for Service Accounts): cada workload que fala com a AWS
# assume a SUA própria role, via token OIDC montado no pod. Nenhuma
# AWS_ACCESS_KEY_ID/SECRET em manifesto, e a role do nó continua sem nenhuma
# permissão de SQS/DynamoDB/ELB.
#
# Usamos o módulo oficial iam-role-for-service-accounts-eks porque ele monta
# a trust policy do OIDC corretamente (o `sub` tem que casar exatamente com
# namespace:serviceaccount, e errar isso gera um AccessDenied difícil de
# depurar).

# --- AWS Load Balancer Controller -------------------------------------------
# attach_load_balancer_controller_policy = true já traz a policy oficial do
# projeto, que é grande e muda entre versões — melhor que copiar JSON na mão.
module "irsa_alb_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${local.name_prefix}-irsa-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# --- evaluation-service: só publica na fila ---------------------------------
data "aws_iam_policy_document" "evaluation" {
  statement {
    sid       = "SendEvaluationEvents"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main.arn]
  }
}

resource "aws_iam_policy" "evaluation" {
  name   = "${local.name_prefix}-evaluation"
  policy = data.aws_iam_policy_document.evaluation.json
}

module "irsa_evaluation" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name_prefix}-irsa-evaluation"

  role_policy_arns = {
    evaluation = aws_iam_policy.evaluation.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.app_namespace}:evaluation-service-sa"]
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
    resources = [aws_sqs_queue.main.arn]
  }

  statement {
    sid       = "WriteAnalyticsTable"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.analytics.arn]
  }
}

resource "aws_iam_policy" "analytics" {
  name   = "${local.name_prefix}-analytics"
  policy = data.aws_iam_policy_document.analytics.json
}

module "irsa_analytics" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name_prefix}-irsa-analytics"

  role_policy_arns = {
    analytics = aws_iam_policy.analytics.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.app_namespace}:analytics-service-sa"]
    }
  }
}

# --- KEDA: só precisa saber o tamanho da fila ------------------------------
# ATENÇÃO ao detalhe que costuma quebrar: quem chama o SQS para decidir
# escalar é o POD DO OPERADOR DO KEDA, não o analytics-service. Por isso a
# trust policy aponta para a Service Account keda:keda-operator (namespace
# keda), e é a SA do operador que recebe a annotation com este role ARN
# (feito no helm_release do módulo cluster-addons).
data "aws_iam_policy_document" "keda" {
  statement {
    sid    = "ReadQueueDepth"
    effect = "Allow"
    actions = [
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.main.arn]
  }
}

resource "aws_iam_policy" "keda" {
  name   = "${local.name_prefix}-keda"
  policy = data.aws_iam_policy_document.keda.json
}

module "irsa_keda" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${local.name_prefix}-irsa-keda"

  role_policy_arns = {
    keda = aws_iam_policy.keda.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["keda:keda-operator"]
    }
  }
}
