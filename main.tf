# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}
provider "azurerm" {
  features {}
}

data "external" "table_schema"{
  program = ["python", "${path.module}/TableSchemaGenerator.py"]

  query = {
    file = "${path.module}/sample.json"
  }
}

locals {
  key_vault_name     = var.key_vault_id != "" ? element(split("/", var.key_vault_id), length(split("/", var.key_vault_id)) - 1) : azurerm_key_vault.kv[0].name
  key_vault_id_final = var.key_vault_id != "" ? var.key_vault_id : azurerm_key_vault.kv.id

  table_columns     = jsondecode(data.external.table_schema.result.columns)
}

# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = "${var.project_name}-rg"
  location = var.region
}

#region Create the log analytics table
# Create the Data Collection Endpoint
resource "azurerm_monitor_data_collection_endpoint" "dce" {
  name                = "${var.project_name}-dce"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

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

# Create the DCR https://github.com/hashicorp/terraform-provider-azurerm/issues/23359
resource "azurerm_monitor_data_collection_rule" "dcr" {
  name                        = "${var.project_name}-dcr"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = azurerm_resource_group.rg.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.dce.id

  destinations {
    log_analytics {
      name                  = var.log_analytics_workspace_id # Parse this for workspace name
      workspace_resource_id = var.log_analytics_workspace_id
    }
  }

  data_flow {
    streams        = ["Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"]
    destinations   = ["${var.log_analytics_workspace_id}"] # Parse this for workspace name
    output_streams = ["Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"]
  }

  stream_declaration {
    stream_name = "Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"
    column {
      name = "TimeGenerated"
      type = "DateTime"
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
  scope                = azurerm_monitor_data_collection_rule.dcr.id
  role_definition_name = "Monitoring Metrics Publisher"
  role_definition_id   = data.azurerm_role_definition.monitoring_metrics_publisher.id
  principal_id         = var.application_principal_id
}
#endregion Create the log analytics table

#region Create the key vault
resource "azurerm_key_vault" "kv" {
  count                    = var.key_vault_id == "" ? 1 : 0
  name                     = "${var.project_name}-kv"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  tenant_id                = var.tenantID
  sku_name                 = "standard"
  soft_delete_enabled      = true
  purge_protection_enabled = false

  access_policy {
    tenant_id          = var.tenantID
    object_id          = azurerm_user_assigned_identity.uai.principal_id
    secret_permissions = ["get", "list"]
  }
}

resource "azurerm_key_vault_secret" "app_secret" {
  name         = var.app_secret_name
  key_vault_id = local.key_vault_id_final
  value        = var.app_secret_value
  content_type = "application/octet-stream"
}
#endregion Create the key vault

#region Create the function app
resource "azurerm_storage_account" "storage" {
  name                     = lower("${var.project_name}str")
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
resource "azurerm_service_plan" "function_app_plan" {
  name                = "${var.project_name}-function-app-plan"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = "Y1"
}

resource "azurerm_windows_function_app" "function_app" {
  name                       = "${var.project_name}-function-app"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_app_plan.id
  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key
  version                    = "~4"

  identity {
    type = "SystemAssigned"
  }
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "powershell"
    "AppId"                    = var.appID                                                                                 # Application ID
    "AppSecret"                = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.kv.name};SecretName=${var.AppSecret})" # Application Secret
    "DCEURI"                   = azurerm_monitor_data_collection_endpoint.dce.ingestion_endpoint
    "DcrImmutableId"           = azurerm_monitor_data_collection_rule.dcr.id
    "streamName"                = "Custom-${azurerm_log_analytics_workspace_table_custom_log.custom_log.name}"
    "TenantId"                 = var.tenantID # Tenant ID
  }
  site_config {
    application_stack {
      powershell_version = "7.4"
    }
  }
}
data "azurerm_windows_function_app" "function_app-wrapper" {
  name                = azurerm_windows_function_app.function_app.name
  resource_group_name = azurerm_resource_group.rg.name
}

# Give function app access to key vault
resource "azurerm_key_vault_access_policy" "function_app_kv_access" {
  key_vault_id = var.key_vault_id # existing key vault ID
  tenant_id    = data.azurerm_windows_function_app.function_app-wrapper.identity.tenant_id
  object_id    = data.azurerm_windows_function_app.function_app-wrapper.identity.principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

resource "azurerm_function_app_function" "function" {
  name             = "${var.project_name}-function"
  function_app_id  = azurerm_windows_function_app.function_app.id
  language         = "PowerShell"
  script_root_path = "/"       # Update with the path to your function code
  script_file      = "run.ps1" # Update with your function's entry script
  entry_point      = "Run"     # Update with your function's entry point
  config_json = jsonencode({
    bindings = [
      {
        authLevel = "Function"
        type      = "httpTrigger"
        direction = "in"
        name      = "req"
        methods   = ["post", "get"]
      },
      {
        type      = "http"
        direction = "out"
        name      = "res"
      }
    ]
  })
  depends_on = [azurerm_windows_function_app.function_app]
}

data "azurerm_function_app_host_keys" "function_app_keys" {
  name                = azurerm_windows_function_app.function_app.name
  resource_group_name = azurerm_resource_group.rg.name
}
#endregion Create the function app

#region Create the API Management and API
resource "azurerm_api_management" "apim" {
  name                = "${var.project_name}-apim"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.project_name
  publisher_email     = "${var.project_name}@terraform.io"

  sku_name = "Consumption_0"
}

resource "azurerm_api_management_api" "api" {
  name                = "${var.project_name}-api"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "${var.project_name} API"
  path                = var.api_path
  protocols           = ["https"]

}

resource "azurerm_api_management_api_operation" "api_operation" {
  operation_id        = "post"
  api_name            = azurerm_api_management_api.api.name
  api_management_name = azurerm_api_management_api.api.api_management_name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "${var.project_name} API by DCR"
  method              = "POST"
  url_template        = "/${var.project_name}"
  description         = "Send data to ${azurerm_function_app_function.function.name} function"
}

resource "azurerm_api_management_backend" "function_app_backend" {
  name                = "${var.project_name}-APIBackend"
  api_management_name = azurerm_api_management_api.api.api_management_name
  resource_group_name = azurerm_resource_group.rg.name
  backend_id          = "${var.project_name}-function-backend"
  url                 = data.azurerm_windows_function_app.function_app-wrapper.default_hostname
  protocol            = "https"
  description         = "Backend for ${azurerm_windows_function_app.function_app.name} function app"

  credentials {
    certificate = []
    header = {
      "x-functions-key" = data.azurerm_function_app_host_keys.function_app_keys.default_function_key
    }
    query = {}
  }
  depends_on = [azurerm_function_app_function.function]
}

# Adding a policy that routes API calls to the function app
resource "azurerm_api_management_api_operation_policy" "api_operation_policy" {
  operation_id        = azurerm_api_management_api_operation.api_operation.operation_id
  api_name            = azurerm_api_management_api.api.name
  api_management_name = azurerm_api_management_api.api.api_management_name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = <<XML
<policies>
    <inbound>
        <base />
        <set-backend-service id="apim-generated-policy" backendbase-url="https://${data.azurerm_windows_function_app.function_app-wrapper.default_hostname}" />
    </inbound>
    <outbound>
        <base />
    </outbound>
    <on-error>
        <base />
    </on-error>
</policies>
XML

  depends_on = [azurerm_function_app_function.function, azurerm_api_management_backend.function_app_backend]
}
#endregion Create the API Management and API
# Output the api URL
output "api_url" {
  value = "${azurerm_api_management_api.api.protocols[0]}://${azurerm_api_management_api.api.api_management_name}.azure-api.net${azurerm_api_management_api_operation.api_operation.url_template}"
}