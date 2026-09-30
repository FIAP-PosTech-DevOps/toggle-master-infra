# Rede de um ambiente: VPC com sub-redes públicas (só o Load Balancer e o
# NAT) e privadas (nós do EKS, RDS e ElastiCache), em 2 AZs.
#
# Usa o módulo oficial terraform-aws-modules/vpc: a malha de route tables,
# associações e NAT tem muitos detalhes fáceis de errar à mão.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  # single_nat_gateway = true => 1 NAT compartilhado entre as AZs (economia de
  # ~US$32/mês por AZ). false = 1 por AZ, resiliente à queda de uma AZ.
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # O default SG da VPC fica sem nenhuma regra: nada usa ele, e um SG default
  # aberto é um achado clássico de auditoria.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Tags que o EKS e o aws-load-balancer-controller usam para descobrir em
  # qual sub-rede criar o Load Balancer. Sem elas o Service do ingress fica
  # em "pending" sem erro claro.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
