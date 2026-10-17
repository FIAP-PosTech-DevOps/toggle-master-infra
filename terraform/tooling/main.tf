# -----------------------------------------------------------------------------
# Laboratório Backstage: uma EC2, separada dos ambientes, que sobe só quando
# vai ser usada (workflow tooling.yml: apply / destroy)
# -----------------------------------------------------------------------------
#
#   sua máquina ──SSM port-forward──► EC2 (Docker)
#   localhost:7007                     ├─ backstage  (imagem do ECR)
#                                      ├─ postgres   (catálogo, só localhost)
#                                      └─ kubectl port-forward ──► ArgoCD de
#                                         cada cluster no ar
#
# Nenhuma porta aberta para a internet: o Security Group não tem regra de
# entrada. O acesso é pelo Session Manager, com as credenciais AWS de quem
# abre o túnel. A EC2 sai para a internet (GitHub, ECR, EKS) por IP público,
# sem NAT Gateway (que custaria mais que a própria máquina).
#
# O que fica no stack global, porque precisa existir com o laboratório
# desligado: a role/instance profile da EC2 (os clusters dão leitura a ela) e
# o repositório ECR da imagem.
# -----------------------------------------------------------------------------

# Amazon Linux 2023 mais recente (já vem com o SSM Agent e o AWS CLI v2).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_instance_profile" "backstage" {
  name = "${var.project_name}-backstage"
}

data "aws_ecr_repository" "backstage" {
  name = "${var.project_name}/backstage"
}

locals {
  name = "${var.project_name}-tooling"

  # "develop:us-east-2:8080 production:us-east-1:8081 staging:us-east-1:8082"
  # -> ambiente, região e a porta local do port-forward até o ArgoCD dele.
  environments = join(" ", [
    for i, env in sort(keys(var.environments)) : "${env}:${var.environments[env]}:${8080 + i}"
  ])

  lab_env = <<-EOT
    PROJECT=${var.project_name}
    AWS_REGION=${var.aws_region}
    ECR_REGISTRY=${split("/", data.aws_ecr_repository.backstage.repository_url)[0]}
    BACKSTAGE_IMAGE=${data.aws_ecr_repository.backstage.repository_url}:${var.image_tag}
    ENVIRONMENTS="${local.environments}"
  EOT

  # Arquivos gravados pelo cloud-init (gzip + base64: o user_data tem limite
  # de 16 KB).
  files = {
    "/opt/backstage/lab.env"                        = { content = local.lab_env, mode = "0644" }
    "/opt/backstage/bootstrap.sh"                   = { content = file("${path.module}/files/bootstrap.sh"), mode = "0755" }
    "/opt/backstage/lab-refresh.sh"                 = { content = file("${path.module}/files/lab-refresh.sh"), mode = "0755" }
    "/etc/systemd/system/argocd-pf@.service"        = { content = file("${path.module}/files/argocd-pf@.service"), mode = "0644" }
    "/etc/systemd/system/backstage-refresh.service" = { content = file("${path.module}/files/backstage-refresh.service"), mode = "0644" }
    "/etc/systemd/system/backstage-refresh.timer"   = { content = file("${path.module}/files/backstage-refresh.timer"), mode = "0644" }
  }

  user_data = join("\n", concat(
    ["#cloud-config", "write_files:"],
    flatten([for path, f in local.files : [
      "  - path: ${path}",
      "    permissions: '${f.mode}'",
      "    encoding: gz+b64",
      "    content: ${base64gzip(f.content)}",
    ]]),
    ["runcmd:", "  - [bash, -c, '/opt/backstage/bootstrap.sh > /var/log/backstage-bootstrap.log 2>&1']"],
  ))
}

# --- Rede: VPC mínima, uma sub-rede pública, sem NAT -------------------------

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:laboratorio descartavel; flow logs custariam mais que o proprio laboratorio
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

# O SG padrão da VPC fica sem nenhuma regra (nada usa ele).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-default-sem-regras" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.vpc_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Sem regra de ENTRADA: ninguém alcança a máquina pela internet. Só saída
# HTTPS (GitHub, ECR, EKS, SSM, PyPI do mkdocs não: já vem na imagem) e HTTP
# para os repositórios de pacotes do Amazon Linux.
resource "aws_security_group" "backstage" {
  name        = "${local.name}-backstage"
  description = "Backstage do laboratorio: sem entrada (acesso via SSM), saida HTTP/HTTPS"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "HTTPS: GitHub, ECR, EKS, SSM, STS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP: repositorios de pacotes do Amazon Linux"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-backstage" }
}

# --- EC2 ---------------------------------------------------------------------

resource "aws_instance" "backstage" {
  #checkov:skip=CKV_AWS_88:IP publico so para SAIDA (sem NAT); o SG nao tem nenhuma regra de entrada
  #checkov:skip=CKV_AWS_126:monitoramento detalhado e pago e desnecessario num laboratorio de horas
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.backstage.id]
  iam_instance_profile        = data.aws_iam_instance_profile.backstage.name
  associate_public_ip_address = true
  ebs_optimized               = true
  user_data                   = local.user_data
  user_data_replace_on_change = true

  # IMDSv2 obrigatório. Hop limit 2: os containers (Docker) também chegam ao
  # metadata para usar a role da instância.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${local.name}-backstage" }

  depends_on = [aws_route_table_association.public]
}
