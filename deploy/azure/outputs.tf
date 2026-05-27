output "api_url" {
  description = "Public HTTPS URL for the Honcho API."
  value       = "https://${azurerm_container_app.api.latest_revision_fqdn}"
}

output "health_url" {
  description = "Health endpoint for the Honcho API."
  value       = "https://${azurerm_container_app.api.latest_revision_fqdn}/health"
}

output "resource_group_name" {
  description = "Azure resource group containing the deployment."
  value       = azurerm_resource_group.main.name
}

output "acr_name" {
  description = "Azure Container Registry name."
  value       = azurerm_container_registry.honcho.name
}

output "image_name" {
  description = "Container image used by the API and deriver."
  value       = local.honcho_image
}

output "api_container_app_name" {
  description = "API Container App name."
  value       = azurerm_container_app.api.name
}

output "deriver_container_app_name" {
  description = "Deriver Container App name."
  value       = azurerm_container_app.deriver.name
}

output "mcp_container_app_name" {
  description = "MCP Container App name."
  value       = azurerm_container_app.mcp.name
}

output "mcp_url" {
  description = "Public HTTPS URL for the Honcho MCP endpoint."
  value = (
    var.enable_mcp_custom_domain_binding
    ? "https://${var.mcp_custom_domain_name}"
    : "https://${azurerm_container_app.mcp.ingress[0].fqdn}"
  )
}

output "mcp_default_url" {
  description = "Default Azure Container Apps HTTPS URL for the Honcho MCP endpoint."
  value       = "https://${azurerm_container_app.mcp.ingress[0].fqdn}"
}

output "mcp_custom_domain_url" {
  description = "Target custom-domain HTTPS URL for the Honcho MCP endpoint."
  value       = "https://${var.mcp_custom_domain_name}"
}

output "mcp_custom_domain_binding_enabled" {
  description = "Whether the MCP Container Apps custom-domain binding resource is enabled."
  value       = var.enable_mcp_custom_domain_binding
}

output "mcp_dns_records_managed" {
  description = "Whether OpenTofu is configured to create the MCP Cloudflare DNS records."
  value       = var.manage_mcp_dns_records
}

output "mcp_custom_domain_dns_records" {
  description = "DNS records required before enabling the MCP managed custom-domain binding."
  value = {
    cname = {
      type  = "CNAME"
      name  = var.mcp_custom_domain_name
      value = azurerm_container_app.mcp.ingress[0].fqdn
    }
    txt = {
      type  = "TXT"
      name  = "asuid.${var.mcp_custom_domain_name}"
      value = nonsensitive(azurerm_container_app.mcp.custom_domain_verification_id)
    }
  }
}

output "postgres_server_name" {
  description = "PostgreSQL Flexible Server name."
  value       = azurerm_postgresql_flexible_server.main.name
}

output "redis_name" {
  description = "Azure Managed Redis name."
  value       = azapi_resource.redis.name
}

output "auth_jwt_secret" {
  description = "Generated or supplied Honcho AUTH_JWT_SECRET. Use it to mint the first admin JWT."
  value       = local.auth_jwt_secret
  sensitive   = true
}

output "create_admin_jwt_command" {
  description = "Run from the repo root to mint an admin JWT for /v3/keys."
  value       = "AUTH_USE_AUTH=true AUTH_JWT_SECRET=\"$(cd deploy/azure && tofu output -raw auth_jwt_secret)\" uv run python -c 'from src.security import create_admin_jwt; print(create_admin_jwt())'"
}

output "manual_acr_build_command" {
  description = "Manual build command if build_image_with_acr_task is false."
  value       = "az acr build --registry ${azurerm_container_registry.honcho.name} --image honcho:${var.image_tag} ${local.repo_root}"
}

output "manual_mcp_acr_build_command" {
  description = "Manual MCP build command if build_mcp_image_with_acr_task is false."
  value       = "az acr build --registry ${azurerm_container_registry.honcho.name} --image honcho-mcp:${var.mcp_image_tag} --file ${local.repo_root}/mcp/Dockerfile ${local.repo_root}/mcp"
}
