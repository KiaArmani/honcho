variable "name" {
  description = "Short deployment name used in Azure resource names."
  type        = string
  default     = "honcho"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{1,20}[a-zA-Z0-9]$", var.name))
    error_message = "Use 3-22 letters, numbers, or hyphens; start and end with a letter or number."
  }
}

variable "environment" {
  description = "Environment label used in names and tags."
  type        = string
  default     = "prod"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Resource group name to create. Leave null to generate one."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "vnet_address_space" {
  description = "Address space for the Honcho virtual network."
  type        = list(string)
  default     = ["10.42.0.0/16"]
}

variable "container_apps_subnet_cidr" {
  description = "CIDR for Container Apps infrastructure subnet. /23 leaves room for scale."
  type        = string
  default     = "10.42.0.0/23"
}

variable "postgres_subnet_cidr" {
  description = "CIDR for the delegated PostgreSQL Flexible Server subnet."
  type        = string
  default     = "10.42.4.0/24"
}

variable "private_endpoints_subnet_cidr" {
  description = "CIDR for private endpoints such as Azure Managed Redis."
  type        = string
  default     = "10.42.5.0/24"
}

variable "container_image" {
  description = "Prebuilt Honcho image. Leave null to use this deployment's ACR image name."
  type        = string
  default     = null
}

variable "image_tag" {
  description = "Image tag used when building/pushing to the managed ACR."
  type        = string
  default     = "latest"
}

variable "build_image_with_acr_task" {
  description = "Build the local repo into ACR during tofu apply using az acr build."
  type        = bool
  default     = true
}

variable "image_rebuild_token" {
  description = "Change this value to force the az acr build step to run again."
  type        = string
  default     = ""
}

variable "mcp_container_image" {
  description = "Prebuilt Honcho MCP image. Leave null to build and use this deployment's ACR image name."
  type        = string
  default     = null
}

variable "mcp_image_tag" {
  description = "Image tag used when building/pushing the Honcho MCP image to the managed ACR."
  type        = string
  default     = "latest"
}

variable "build_mcp_image_with_acr_task" {
  description = "Build the local mcp/ package into ACR during tofu apply using az acr build."
  type        = bool
  default     = true
}

variable "mcp_image_rebuild_token" {
  description = "Change this value to force the MCP az acr build step to run again."
  type        = string
  default     = ""
}

variable "acr_sku" {
  description = "ACR SKU. Basic is cheapest and works with managed identity pulls; Premium is required for private endpoints."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard, or Premium."
  }
}

variable "acr_public_network_access_enabled" {
  description = "Keep ACR publicly reachable for authenticated build/push. Set false only with Premium plus private build runners."
  type        = bool
  default     = true
}

variable "log_analytics_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "log_analytics_daily_quota_gb" {
  description = "Daily Log Analytics ingestion cap. Use -1 for unlimited."
  type        = number
  default     = 1
}

variable "api_min_replicas" {
  description = "Minimum API replicas. Production default avoids cold starts."
  type        = number
  default     = 1
}

variable "api_max_replicas" {
  description = "Maximum API replicas."
  type        = number
  default     = 3
}

variable "api_cpu" {
  description = "API container CPU cores."
  type        = number
  default     = 0.5
}

variable "api_memory" {
  description = "API container memory."
  type        = string
  default     = "1Gi"
}

variable "deriver_min_replicas" {
  description = "Minimum deriver replicas. Keep at 1 unless you have tested queue throughput."
  type        = number
  default     = 1
}

variable "deriver_max_replicas" {
  description = "Maximum deriver replicas."
  type        = number
  default     = 1
}

variable "deriver_cpu" {
  description = "Deriver container CPU cores."
  type        = number
  default     = 0.5
}

variable "deriver_memory" {
  description = "Deriver container memory."
  type        = string
  default     = "1Gi"
}

variable "mcp_min_replicas" {
  description = "Minimum MCP replicas. Keep 0 for low-cost scale-to-zero."
  type        = number
  default     = 0
}

variable "mcp_max_replicas" {
  description = "Maximum MCP replicas."
  type        = number
  default     = 2
}

variable "mcp_cpu" {
  description = "MCP container CPU cores."
  type        = number
  default     = 0.25
}

variable "mcp_memory" {
  description = "MCP container memory."
  type        = string
  default     = "0.5Gi"
}

variable "mcp_honcho_api_url" {
  description = "Raw Honcho API URL that the MCP server proxies to."
  type        = string
  default     = "https://honcho.llm.kia.dev"

  validation {
    condition     = can(regex("^https://", var.mcp_honcho_api_url))
    error_message = "mcp_honcho_api_url must be an https:// URL."
  }
}

variable "mcp_custom_domain_name" {
  description = "Custom domain to bind to the MCP Container App after DNS validation records are in place."
  type        = string
  default     = "mcp.honcho.llm.kia.dev"
}

variable "enable_mcp_custom_domain_binding" {
  description = "Set true only after the MCP CNAME and TXT validation records have propagated."
  type        = bool
  default     = false
}

variable "manage_mcp_dns_records" {
  description = "When true, create the MCP custom-domain CNAME and TXT records in Cloudflare DNS."
  type        = bool
  default     = false
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the public DNS zone that contains mcp_custom_domain_name. Required when manage_mcp_dns_records is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "postgres_version" {
  description = "Azure Database for PostgreSQL Flexible Server major version."
  type        = string
  default     = "15"
}

variable "postgres_admin_username" {
  description = "PostgreSQL administrator username."
  type        = string
  default     = "honchoadmin"
}

variable "postgres_database_name" {
  description = "PostgreSQL database name for Honcho."
  type        = string
  default     = "honcho"
}

variable "postgres_sku_name" {
  description = "Flexible Server SKU. B_Standard_B1ms is the cheapest viable SKU; switch to GP_Standard_D2ds_v5 before enabling HA."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage in MB."
  type        = number
  default     = 32768
}

variable "postgres_backup_retention_days" {
  description = "PostgreSQL backup retention in days."
  type        = number
  default     = 7
}

variable "postgres_geo_redundant_backup_enabled" {
  description = "Enable geo-redundant PostgreSQL backups. More resilient, higher cost."
  type        = bool
  default     = false
}

variable "postgres_high_availability_enabled" {
  description = "Enable zone-redundant PostgreSQL HA. Production-grade but roughly doubles database cost."
  type        = bool
  default     = false
}

variable "postgres_standby_availability_zone" {
  description = "Standby AZ for PostgreSQL HA. Null lets Azure choose."
  type        = string
  default     = null
}

variable "db_pool_size" {
  description = "Honcho DB_POOL_SIZE injected into API and deriver."
  type        = number
  default     = 5
}

variable "db_max_overflow" {
  description = "Honcho DB_MAX_OVERFLOW injected into API and deriver."
  type        = number
  default     = 10
}

variable "redis_sku_name" {
  description = "Azure Managed Redis SKU. Balanced_B0 is the smallest current Managed Redis SKU with Private Link support."
  type        = string
  default     = "Balanced_B0"
}

variable "redis_capacity" {
  description = "Redis capacity. Only set for SKUs that require capacity."
  type        = number
  default     = null
}

variable "redis_high_availability_enabled" {
  description = "Enable Redis high availability. Recommended for production resilience, disabled by default to reduce baseline cost."
  type        = bool
  default     = false
}

variable "redis_eviction_policy" {
  description = "Redis eviction policy for Honcho cache data."
  type        = string
  default     = "VolatileLRU"
}

variable "auth_jwt_secret" {
  description = "Honcho AUTH_JWT_SECRET. Leave null to generate one."
  type        = string
  default     = null
  sensitive   = true
}

variable "llm_openai_api_key" {
  description = "Optional LLM_OPENAI_API_KEY. Required for Honcho's built-in model defaults."
  type        = string
  default     = ""
  sensitive   = true
}

variable "llm_anthropic_api_key" {
  description = "Optional LLM_ANTHROPIC_API_KEY."
  type        = string
  default     = ""
  sensitive   = true
}

variable "llm_gemini_api_key" {
  description = "Optional LLM_GEMINI_API_KEY."
  type        = string
  default     = ""
  sensitive   = true
}

variable "honcho_env" {
  description = "Non-secret Honcho environment overrides. See .env.example for available keys."
  type        = map(string)
  default     = {}
}

variable "honcho_secret_env" {
  description = "Additional secret Honcho environment variables, such as WEBHOOK_SECRET or provider-specific keys."
  type        = map(string)
  default     = {}
  sensitive   = true
}
