resource "kubernetes_namespace" "app" {
  metadata {
    name = var.app_namespace
  }
}

# As Service Accounts dos 2 serviços que falam com a AWS. A annotation
# eks.amazonaws.com/role-arn é o que faz o EKS injetar o token OIDC no pod —
# é o "clique" que liga o IRSA.
#
# Os Deployments (aplicados pelo k8s/deploy.sh)
# precisam referenciar estes nomes em spec.template.spec.serviceAccountName,
# senão os pods usam a SA "default" e recebem AccessDenied da AWS.
resource "kubernetes_service_account" "evaluation" {
  metadata {
    name      = "evaluation-service-sa"
    namespace = kubernetes_namespace.app.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = local.irsa_role_arns.evaluation
    }
  }
}

resource "kubernetes_service_account" "analytics" {
  metadata {
    name      = "analytics-service-sa"
    namespace = kubernetes_namespace.app.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = local.irsa_role_arns.analytics
    }
  }
}

# Não existe SA de KEDA aqui de propósito: quem consulta o SQS é o pod do
# operador do KEDA, no namespace keda. Essa SA é criada pelo chart do KEDA e
# recebe a annotation via helm_release — ver keda.tf.
