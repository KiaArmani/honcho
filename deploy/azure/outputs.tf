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
