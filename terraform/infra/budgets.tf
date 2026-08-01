# Com crédito limitado, o alarme de orçamento é a rede de proteção mais
# importante deste projeto. Ele é criado junto com o resto, então já está
# ativo desde o primeiro recurso cobrado.
#
# Você vai receber um e-mail de confirmação do SNS/Budgets — confirme, senão
# os alertas não chegam.
resource "aws_budgets_budget" "lab" {
  name         = "${local.name_prefix}-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 50% do teto: só um aviso de que o consumo começou.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # 80% do teto: hora de rodar o destroy se não estiver usando.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # FORECASTED: avisa quando a AWS PREVÊ que você vai passar do teto,
  # antes de acontecer.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
