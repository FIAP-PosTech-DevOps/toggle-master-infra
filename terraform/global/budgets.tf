# Um orçamento para a CONTA, não por ambiente: o crédito é um só, e três
# alarmes independentes de US$80 deixariam passar um gasto somado de US$240.
#
# Confirme o e-mail de inscrição que a AWS envia, senão os alertas não chegam.
resource "aws_budgets_budget" "account" {
  name         = "${var.project_name}-account-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 50%: só um aviso de que o consumo começou.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # 80%: hora de destruir o que não estiver em uso.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # FORECASTED: a AWS prevê que o mês vai passar do teto.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
