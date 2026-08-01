module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = local.name_prefix
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  # single_nat_gateway = true => 1 NAT compartilhado entre as AZs (economia).
  # Troque para false se precisar de resiliência total de saída à internet e o
  # orçamento permitir (cada NAT extra custa ~US$32/mês).
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags que o EKS e o aws-load-balancer-controller usam para descobrir
  # sozinhos em qual sub-rede colocar o Load Balancer. Sem elas o Ingress
  # fica pendurado em "pending" sem erro claro.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
