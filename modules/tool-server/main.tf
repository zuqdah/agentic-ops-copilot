resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.name}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  tags                       = var.tags
}

locals {
  # The MCP transport rejects every request whose Host header isn't
  # allowlisted, and the app can't read its own FQDN before it exists.
  # The environment's domain is known first, so derive the hostname here.
  fqdn = "ca-${var.name}.${azurerm_container_app_environment.this.default_domain}"
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${var.name}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  # Resolved from Key Vault at runtime by the app's managed identity; the
  # value never appears in app configuration or Terraform-rendered settings.
  secret {
    name                = "lab-key"
    key_vault_secret_id = var.lab_key_secret_id
    identity            = var.identity_id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = var.max_replicas

    container {
      name   = "tools"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = merge(var.env, { PUBLIC_HOSTNAME = local.fqdn })
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "LAB_KEY"
        secret_name = "lab-key"
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8000
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8000
      }
    }

    http_scale_rule {
      name                = "http"
      concurrent_requests = "20"
    }
  }

  tags = var.tags
}
