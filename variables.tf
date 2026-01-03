variable "project_name" {
  description = "The name of the project that will be used to name the LA table"
  type        = string

  validation {
    condition     = length(var.project_name) < 41 && length(var.project_name) > 0 && can(regex("^[^\\s]*$", var.project_name))
    error_message = "The project_name variable must not be empty and must be less than 40 characters with no spaces."
  }
}

variable "resource_group_name" {
  type        = string
  description = "The name of the resource group where resources will be created."
  default     = ""
}

variable "tenant_id" {
  type        = string
  default     = ""
  description = "The Tenant ID of the Azure Active Directory."
}

variable "log_analytics_workspace_id" {
  type        = string
  default     = ""
  description = "The ID of an existing Key Vault to store secrets. If not provided, a new Key Vault will be created."
}

variable "appID" {
  type        = string
  default     = ""
  description = "Client ID of the Azure AD application or managed identity that should be granted Monitoring Metrics Publisher on the DCR."
}

variable "appServicePrincipalID" {
  type        = string
  default     = ""
  description = "Service Principal ID of the Azure AD application or managed identity that should be granted Monitoring Metrics Publisher on the DCR."
}

variable "app_secret_value" {
  type        = string
  description = "Value of the application secret (supply at runtime)"
  sensitive   = true
  default     = ""
}