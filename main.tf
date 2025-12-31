# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.57.0"
    }
  }
}

data "azurerm_client_config" "current" {}

data "external" "table_schema" {
  program = ["python", "${path.module}/TableSchemaGenerator.py"]

  query = {
    file = "${path.module}/sample.json"
  }
}

locals {
  key_vault_name     = var.key_vault_id != "" ? element(split("/", var.key_vault_id), length(split("/", var.key_vault_id)) - 1) : azurerm_key_vault.kv[0].name
  key_vault_id_final = var.key_vault_id != "" ? var.key_vault_id : azurerm_key_vault.kv[0].id

  table_columns = jsondecode(data.external.table_schema.result.columns)
}

# Create a resource group
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

#region Create the log analytics table
# Create the Data Collection Endpoint
resource "azurerm_monitor_data_collection_endpoint" "dce" {
  name                = "${var.project_name}-dce"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location

  lifecycle {
    create_before_destroy = true
  }
}

# Create the log analytics table azurerm way
resource "azurerm_log_analytics_workspace_table_custom_log" "custom_log" {
  name         = "${var.project_name}_CL"
  workspace_id = var.log_analytics_workspace_id

  column {
    name = "TimeGenerated"
    type = "dateTime"
  }
  dynamic "column" {
    for_each = local.table_columns
    content {
      name = column.value.name
      type = column.value.type
    }
  }
}

# Create the DCR https://github.com/hashicorp/terraform-provider-azurerm/issues/23359
resource "azurerm_monitor_data_collection_rule" "dcr" {
  name                        = "${var.project_name}-dcr"
  resource_group_name         = data.azurerm_resource_group.rg.name
  location                    = data.azurerm_resource_group.rg.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.dce.id

  destinations {
    log_analytics {
      name                  = element(split("/", var.log_analytics_workspace_id), length(split("/", var.log_analytics_workspace_id)) - 1) # Parse this for workspace name
      workspace_resource_id = var.log_analytics_workspace_id
    }
  }

  data_flow {
    streams       = ["Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"]
    destinations  = [element(split("/", var.log_analytics_workspace_id), length(split("/", var.log_analytics_workspace_id)) - 1)] # Parse this for workspace name
    output_stream = "Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"
  }

  stream_declaration {
    stream_name = "Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    dynamic "column" {
      for_each = local.table_columns
      content {
        name = column.value.name
        type = column.value.type
      }
    }
  }
  identity {
    type = "SystemAssigned"
  }
  description = "Data Collection Rule for ${var.project_name} created using Terraform"

  depends_on = [azurerm_log_analytics_workspace_table_custom_log.custom_log]
}

# Assign the role to the DCR
data "azurerm_role_definition" "monitoring_metrics_publisher" {
  name  = "Monitoring Metrics Publisher"
  scope = azurerm_monitor_data_collection_rule.dcr.id
}

resource "azurerm_role_assignment" "dcr_monitoring_metrics_publisher" {
  scope = azurerm_monitor_data_collection_rule.dcr.id
  #role_definition_name = "Monitoring Metrics Publisher"
  role_definition_id = data.azurerm_role_definition.monitoring_metrics_publisher.id
  principal_id       = var.appServicePrincipalID
}
#endregion Create the log analytics table

#region Create the key vault
resource "azurerm_key_vault" "kv" {
  count                    = var.key_vault_id == "" ? 1 : 0
  name                     = "${var.project_name}-kv"
  location                 = data.azurerm_resource_group.rg.location
  resource_group_name      = data.azurerm_resource_group.rg.name
  tenant_id                = data.azurerm_client_config.current.tenant_id
  sku_name                 = "standard"
  purge_protection_enabled = false
}

resource "azurerm_key_vault_secret" "app_secret" {
  name         = var.appID
  key_vault_id = local.key_vault_id_final
  value        = var.app_secret_value
  content_type = "application/octet-stream"

  depends_on = [azurerm_key_vault_access_policy.terraform_kv_access]
}
#endregion Create the key vault

#region Create the function app

# turn on application insights
# This will autogenerate a smart detection rule unmanaged by Terraform
# https://github.com/hashicorp/terraform-provider-azurerm/issues/18026
resource "azurerm_application_insights" "functionapp_insights" {
  name                = "${var.project_name}-ai"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = var.log_analytics_workspace_id
  application_type    = "web"
}

resource "azurerm_monitor_action_group" "appinsightsactiongroup" {
  name                = "Application Insights Smart Detection"
  resource_group_name = data.azurerm_resource_group.rg.name
  short_name          = "SmartDetect"
}

resource "azurerm_monitor_smart_detector_alert_rule" "appinsightsalertrule" {
  name                = "FailureAnomaliesDetector"
  resource_group_name = data.azurerm_resource_group.rg.name
  severity            = "Sev0"
  scope_resource_ids  = [azurerm_application_insights.functionapp_insights.id]
  frequency           = "PT1M"
  detector_type       = "FailureAnomaliesDetector"

  action_group {
    ids = [azurerm_monitor_action_group.appinsightsactiongroup.id]
  }
}

resource "azurerm_storage_account" "storage" {
  name                     = lower("${var.project_name}str")
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
resource "azurerm_service_plan" "function_app_plan" {
  name                = "${var.project_name}-function-app-plan"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = "Y1"
}

resource "azurerm_windows_function_app" "function_app" {
  name                       = "${var.project_name}-function-app"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_app_plan.id
  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key

  identity {
    type = "SystemAssigned"
  }
  app_settings = {
    "AppId"          = var.appID                                                                                                               # Application ID
    "AppSecret"      = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.kv[0].name};SecretName=${azurerm_key_vault_secret.app_secret.name})" # Application Secret
    "DceURI"         = azurerm_monitor_data_collection_endpoint.dce.logs_ingestion_endpoint
    "DcrImmutableId" = azurerm_monitor_data_collection_rule.dcr.immutable_id
    "TableName"      = "Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"
    "TenantID"       = data.azurerm_client_config.current.tenant_id # Tenant ID
  }
  site_config {
    application_stack {
      powershell_core_version = "7.4"
    }
    application_insights_connection_string = azurerm_application_insights.functionapp_insights.connection_string
  }
}
data "azurerm_windows_function_app" "function_app-wrapper" {
  name                = azurerm_windows_function_app.function_app.name
  resource_group_name = data.azurerm_resource_group.rg.name
}

# Give function app access to key vault
resource "azurerm_key_vault_access_policy" "function_app_kv_access" {
  key_vault_id = local.key_vault_id_final # existing key vault ID
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_windows_function_app.function_app-wrapper.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

# Give terraform access to key vault
resource "azurerm_key_vault_access_policy" "terraform_kv_access" {
  key_vault_id = local.key_vault_id_final # existing key vault ID
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge"
  ]
}

resource "azurerm_function_app_function" "function" {
  name            = "${var.project_name}"
  function_app_id = azurerm_windows_function_app.function_app.id
  language        = "PowerShell"

  file {
    name    = "run.ps1"
    content = file("${path.module}/run.ps1")
  }

  config_json = jsonencode({
    bindings = [
      {
        authLevel = "Function"
        type      = "httpTrigger"
        direction = "in"
        name      = "Request"
        methods   = ["post", "get"]
      },
      {
        type      = "http"
        direction = "out"
        name      = "Response"
      }
    ]
  })
  depends_on = [azurerm_windows_function_app.function_app]
}

data "azurerm_function_app_host_keys" "function_app_keys" {
  name                = azurerm_windows_function_app.function_app.name
  resource_group_name = data.azurerm_resource_group.rg.name
}

#endregion Create the function app

#region Create the API Management and API
resource "azurerm_api_management" "apim" {
  name                = "${var.project_name}-apim"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  publisher_name      = var.project_name
  publisher_email     = "${var.project_name}@terraform.io"

  sku_name = "Consumption_0"
}

resource "azurerm_api_management_api" "api" {
  name                  = "${var.project_name}-api"
  resource_group_name   = data.azurerm_resource_group.rg.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "${var.project_name} API"
  protocols             = ["https"]
  subscription_required = false

}

resource "azurerm_api_management_api_operation" "api_operation" {
  operation_id        = "post"
  api_name            = azurerm_api_management_api.api.name
  api_management_name = azurerm_api_management_api.api.api_management_name
  resource_group_name = data.azurerm_resource_group.rg.name
  display_name        = "${var.project_name} API by DCR"
  method              = "POST"
  url_template        = "/${var.project_name}"
  description         = "Send data to ${azurerm_function_app_function.function.name} function"
}

resource "azurerm_api_management_backend" "function_app_backend" {
  name                = "${azurerm_windows_function_app.function_app.name}-backend"
  api_management_name = azurerm_api_management_api.api.api_management_name
  resource_group_name = data.azurerm_resource_group.rg.name
  resource_id         = "https://management.azure.com${azurerm_windows_function_app.function_app.id}"
  url                 = "https://${data.azurerm_windows_function_app.function_app-wrapper.default_hostname}/api/${azurerm_function_app_function.function.name}" # /api/${azurerm_function_app_function.function.name}"
  protocol            = "http"
  description         = "Backend for ${azurerm_windows_function_app.function_app.name} function app"

  credentials {
    query = {
      code = data.azurerm_function_app_host_keys.function_app_keys.default_function_key
    }
  }
  depends_on = [azurerm_function_app_function.function]
}

# Adding a policy that routes API calls to the function app
resource "azurerm_api_management_api_operation_policy" "api_operation_policy" {
  operation_id        = azurerm_api_management_api_operation.api_operation.operation_id
  api_name            = azurerm_api_management_api.api.name
  api_management_name = azurerm_api_management_api.api.api_management_name
  resource_group_name = data.azurerm_resource_group.rg.name
  #id="apim-generated-policy"
  xml_content = <<XML
<policies>
    <inbound>
        <base />
        <set-backend-service id="apim-generated-policy" backend-id="${azurerm_api_management_backend.function_app_backend.name}" />
    </inbound>
    <outbound>
        <base />
    </outbound>
    <on-error>
        <base />
    </on-error>
</policies>
XML

  depends_on = [azurerm_function_app_function.function, azurerm_api_management_api.api, azurerm_api_management_backend.function_app_backend]
}
#endregion Create the API Management and API
# Output the api URL
output "api_url" {
  value = "https://${azurerm_api_management_api.api.api_management_name}.azure-api.net${azurerm_api_management_api_operation.api_operation.url_template}"
}