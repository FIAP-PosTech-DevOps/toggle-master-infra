# Este controller é o que cria o Network Load Balancer de verdade na AWS
# quando o Service do ingress-nginx pede um LoadBalancer. Ele roda com IRSA,
# ou seja: a permissão de mexer em Load Balancer é do POD dele, não do nó —
# exatamente o que o desafio pede na Opção B.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.alb_controller_chart_version

  set {
    name  = "clusterName"
    value = local.cluster_name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = local.vpc_id
  }

  # Imagem via pull-through cache do ECR em vez de public.ecr.aws direto.
  set {
    name  = "image.repository"
    value = "${local.registry_ecr_public}/eks/aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # As barras invertidas escapam os pontos: sem isso o Helm interpretaria
  # "eks.amazonaws.com/role-arn" como chaves aninhadas.
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa_role_arns.alb_controller
  }

  # Espera os pods ficarem Ready antes de dar o release por concluído. Sem
  # isso o Terraform seguiria adiante com o webhook já registrado mas sem
  # endpoint atrás dele, quebrando a criação de Services dos outros charts.
  wait          = true
  wait_for_jobs = true
  timeout       = 600
}
