resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = var.keda_chart_version

  # A SA do operador recebe o role ARN — é este pod que chama
  # sqs:GetQueueAttributes para decidir quantas réplicas o analytics-service
  # deve ter. A role correspondente (infra/irsa.tf) confia exatamente em
  # keda:keda-operator.
  # As imagens do KEDA vêm de ghcr.io, que exigiria credencial para
  # pull-through cache. Por isso elas são espelhadas para o ECR pelo script
  # k8s/mirror-images.sh — rode-o ANTES deste apply, senão os pods ficam em
  # ImagePullBackOff.
  #
  # ATENÇÃO à estrutura deste chart: o host fica separado do caminho, e o host
  # é definido POR COMPONENTE (image.keda.registry, image.metricsApiServer.
  # registry, image.webhooks.registry — todos default ghcr.io). Existe também
  # global.image.registry, que sobrescreve os três de uma vez — é o que
  # usamos aqui.
  #
  # Não existe "image.registry" isolado: passar essa chave é ignorado em
  # silêncio pelo Helm, e o resultado é uma referência inválida do tipo
  # "ghcr.io/mirror/kedacore/keda".
  set {
    name  = "global.image.registry"
    value = local.ecr_registry
  }

  set {
    name  = "image.keda.repository"
    value = "mirror/kedacore/keda"
  }

  set {
    name  = "image.metricsApiServer.repository"
    value = "mirror/kedacore/keda-metrics-apiserver"
  }

  set {
    name  = "image.webhooks.repository"
    value = "mirror/kedacore/keda-admission-webhooks"
  }

  set {
    name  = "podIdentity.aws.irsa.enabled"
    value = "true"
  }

  set {
    name  = "podIdentity.aws.irsa.roleArn"
    value = local.irsa_role_arns.keda
  }

  # OBRIGATÓRIO. O chart do ALB controller registra um mutating webhook que
  # intercepta a criação de TODO Service do cluster. Enquanto os pods do
  # controller não estão Ready, qualquer Service novo falha com
  # "no endpoints available for service aws-load-balancer-webhook-service".
  # O KEDA cria três Services, então sem este depends_on o Terraform o instala
  # em paralelo e ele cai exatamente nessa janela.
  depends_on = [helm_release.aws_load_balancer_controller]

  # O default de 300s é apertado: além de subir 3 deployments, o KEDA gera o
  # secret de certificados (kedaorg-certs) e os pods ficam em FailedMount até
  # isso concluir. Com pull vindo de cache frio, 5 minutos estouram.
  timeout = 900
}

# O TriggerAuthentication e o ScaledObject do analytics-service ficam como
# manifestos kubectl comuns (k8s/09-keda-analytics.yaml), e não como
# kubernetes_manifest do Terraform: o kubernetes_manifest precisa do schema
# do CRD já registrado no cluster durante o `plan`, o que não existe na
# primeira apply — o CRD só nasce quando este helm_release roda. Aplicar via
# kubectl depois deste módulo evita esse problema clássico de ovo-e-galinha.
