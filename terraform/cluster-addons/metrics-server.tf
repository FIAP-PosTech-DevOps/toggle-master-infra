# Sem o metrics-server o HPA não consegue ler CPU e fica com
# "unknown/70%" para sempre. É pré-requisito do HPA do evaluation-service.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = var.metrics_server_chart_version

  # Imagem via pull-through cache do ECR em vez de registry.k8s.io direto.
  set {
    name  = "image.repository"
    value = "${local.registry_k8s}/metrics-server/metrics-server"
  }

  # Mesmo motivo do KEDA: o metrics-server também cria um Service, e o webhook
  # do ALB controller intercepta a criação de Services em todo o cluster.
  # Serializar evita a corrida.
  depends_on = [helm_release.aws_load_balancer_controller]
}
