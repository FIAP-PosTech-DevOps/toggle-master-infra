# terraform/tooling — laboratório Backstage

Stack separado dos ambientes (state `tooling/terraform.tfstate`): VPC mínima e uma EC2 com o Backstage, criada e destruída pelo workflow `tooling.yml` (*Actions › tooling › Run workflow*).

Guia completo (preparação, uso, diagnóstico e custo): [docs/backstage-lab.md](../../docs/backstage-lab.md).

```bash
./tf.sh tooling plan
./tf.sh tooling apply
./tf.sh tooling output -raw tunnel_command
./tf.sh tooling destroy
```

| Arquivo | O que faz |
|---|---|
| `main.tf` | VPC, sub-rede pública, Security Group sem entrada, EC2 com o cloud-init |
| `files/bootstrap.sh` | Instala Docker e kubectl, lê os segredos do SSM, sobe Postgres e Backstage |
| `files/lab-refresh.sh` | A cada 2 min: clusters e ArgoCD no ar → `app-config.lab.yaml` |
| `files/argocd-pf@.service` | Port-forward até o ArgoCD de cada ambiente |
