locals {
  normalized_name = replace(lower(var.name), "/[^a-z0-9-]/", "-")
  normalized_env  = replace(lower(var.environment), "/[^a-z0-9-]/", "-")
  name_prefix     = substr("${local.normalized_name}-${local.normalized_env}", 0, 32)
  compact_prefix  = substr(replace(local.name_prefix, "/[^a-z0-9]/", ""), 0, 20)

  repo_root = abspath("${path.module}/../..")

  image_source_files = distinct(concat(
    tolist(fileset(local.repo_root, "src/**")),
    tolist(fileset(local.repo_root, "migrations/**")),
    tolist(fileset(local.repo_root, "scripts/**")),
    tolist(fileset(local.repo_root, "docker/**")),
    [
      ".dockerignore",
      "Dockerfile",
      "deploy/azure/Dockerfile.acr",
      "pyproject.toml",
      "uv.lock",
      "alembic.ini",
      "config.toml.example",
    ],
  ))

  image_source_hash = sha256(join("", [
    for file_name in sort(local.image_source_files) : filesha256("${local.repo_root}/${file_name}")
  ]))

  tags = merge(
    {
      application = "honcho"
      environment = var.environment
      managed_by  = "opentofu"
    },
    var.tags,
  )
}

resource "random_string" "suffix" {
  length  = 8
  lower   = true
  numeric = true
  special = false
  upper   = false
}

resource "random_password" "postgres" {
  length           = 32
  special          = true
  override_special = "_%@"
}

resource "random_password" "auth_jwt" {
  length  = 48
  special = false
}

locals {
  resource_group_name = coalesce(var.resource_group_name, "rg-${local.name_prefix}-${random_string.suffix.result}")
  acr_name            = substr("acr${local.compact_prefix}${random_string.suffix.result}", 0, 50)
  api_app_name        = substr("${local.name_prefix}-api-${random_string.suffix.result}", 0, 32)
  deriver_app_name    = substr("${local.name_prefix}-deriver-${random_string.suffix.result}", 0, 32)
  postgres_name       = substr("${local.name_prefix}-pg-${random_string.suffix.result}", 0, 63)
  redis_name          = substr("${local.name_prefix}-redis-${random_string.suffix.result}", 0, 60)

  api_startup_command = join(" && ", [
    "/app/.venv/bin/python scripts/provision_db.py",
    "/app/.venv/bin/python scripts/configure_embeddings.py --yes",
    "exec /app/.venv/bin/fastapi run --host 0.0.0.0 src/main.py",
  ])

  deriver_startup_command = join(" ", [
    "until /app/.venv/bin/python scripts/configure_embeddings.py --yes; do",
    "echo 'Waiting for embedding schema bootstrap...';",
    "sleep 10;",
    "done;",
    "exec /app/.venv/bin/python -m src.deriver",
  ])
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "container_apps" {
  name                 = "snet-container-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.container_apps_subnet_cidr]

  delegation {
    name = "container-apps"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.postgres_subnet_cidr]

  delegation {
    name = "postgres-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.private_endpoints_subnet_cidr]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-${random_string.suffix.result}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = local.postgres_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = var.postgres_version
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false
  administrator_login           = var.postgres_admin_username
  administrator_password        = random_password.postgres.result
  sku_name                      = var.postgres_sku_name
  storage_mb                    = var.postgres_storage_mb
  backup_retention_days         = var.postgres_backup_retention_days
  geo_redundant_backup_enabled  = var.postgres_geo_redundant_backup_enabled
  tags                          = local.tags

  dynamic "high_availability" {
    for_each = var.postgres_high_availability_enabled ? [1] : []

    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = var.postgres_standby_availability_zone
    }
  }

  lifecycle {
    ignore_changes = [zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_configuration" "pgvector_allowlist" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "VECTOR"
}

resource "azurerm_postgresql_flexible_server_database" "honcho" {
  name      = var.postgres_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [azurerm_postgresql_flexible_server_configuration.pgvector_allowlist]
}

resource "azapi_resource" "redis" {
  type      = "Microsoft.Cache/redisEnterprise@2025-07-01"
  parent_id = azurerm_resource_group.main.id
  name      = local.redis_name
  location  = azurerm_resource_group.main.location
  tags      = local.tags

  body = {
    properties = {
      encryption          = {}
      highAvailability    = var.redis_high_availability_enabled ? "Enabled" : "Disabled"
      minimumTlsVersion   = "1.2"
      publicNetworkAccess = "Disabled"
    }
    sku = merge(
      { name = var.redis_sku_name },
      var.redis_capacity == null ? {} : { capacity = var.redis_capacity },
    )
  }

  identity {
    type         = "SystemAssigned"
    identity_ids = []
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.hostName"]
}

resource "azapi_resource" "redis_database" {
  type      = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  parent_id = azapi_resource.redis.id
  name      = "default"

  body = {
    properties = {
      accessKeysAuthentication = "Enabled"
      clientProtocol           = "Encrypted"
      clusteringPolicy         = "OSSCluster"
      evictionPolicy           = var.redis_eviction_policy
      modules                  = []
      port                     = 10000
    }
  }

  schema_validation_enabled = false
}

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "redis-${random_string.suffix.result}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-${local.redis_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.redis_name}"
    private_connection_resource_id = azapi_resource.redis.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }

  depends_on = [
    azapi_resource.redis_database,
    azurerm_private_dns_zone_virtual_network_link.redis,
  ]
}

data "azapi_resource_action" "redis_keys" {
  type                   = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  resource_id            = azapi_resource.redis_database.id
  action                 = "listKeys"
  method                 = "POST"
  response_export_values = ["primaryKey"]

  depends_on = [azapi_resource.redis_database]
}

resource "azurerm_container_registry" "honcho" {
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku                           = var.acr_sku
  admin_enabled                 = false
  public_network_access_enabled = var.acr_public_network_access_enabled
  anonymous_pull_enabled        = false
  tags                          = local.tags
}

locals {
  honcho_image = coalesce(var.container_image, "${azurerm_container_registry.honcho.login_server}/honcho:${var.image_tag}")
}

resource "terraform_data" "acr_build" {
  count = var.container_image == null && var.build_image_with_acr_task ? 1 : 0

  triggers_replace = {
    image_tag     = var.image_tag
    rebuild_token = var.image_rebuild_token
    source_hash   = local.image_source_hash
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu

      for attempt in 1 2 3 4 5 6; do
        if az acr show --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_container_registry.honcho.name} >/dev/null 2>&1; then
          break
        fi

        if [ "$attempt" = "6" ]; then
          az acr show --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_container_registry.honcho.name}
        fi

        sleep 10
      done

      for attempt in 1 2 3 4 5 6; do
        build_log="$(mktemp)"

        if az acr build \
          --resource-group ${azurerm_resource_group.main.name} \
          --registry ${azurerm_container_registry.honcho.name} \
          --image honcho:${var.image_tag} \
          --file ${abspath("${path.module}/Dockerfile.acr")} \
          ${local.repo_root} >"$build_log" 2>&1; then
          cat "$build_log"
          rm -f "$build_log"
          exit 0
        fi

        cat "$build_log"

        if ! grep -Eq "ParentResourceNotFound|ResourceNotFound|listBuildSourceUploadUrl|could not be found" "$build_log"; then
          rm -f "$build_log"
          exit 1
        fi

        rm -f "$build_log"

        if [ "$attempt" = "6" ]; then
          exit 1
        fi

        sleep 30
      done
    EOT
  }

  depends_on = [azurerm_container_registry.honcho]
}

resource "terraform_data" "deployment_guards" {
  input = "validate-required-runtime-secrets"

  lifecycle {
    precondition {
      condition     = local.embedding_vector_dimensions != null
      error_message = "honcho_env.EMBEDDING_VECTOR_DIMENSIONS must be a number when set."
    }

    precondition {
      condition = (
        local.embedding_vector_dimensions == null
        ? true
        : local.embedding_vector_dimensions <= 2000
      )
      error_message = "This deployment uses pgvector HNSW indexes, which support at most 2000 dimensions. Keep EMBEDDING_VECTOR_DIMENSIONS at 1536 for the default embedding schema, or disable/replace the pgvector HNSW path before using a larger embedding size."
    }

    precondition {
      condition = (
        !var.postgres_high_availability_enabled
        || !can(regex("^B_", var.postgres_sku_name))
      )
      error_message = "PostgreSQL Burstable SKUs such as B_Standard_B1ms do not support HA. Set postgres_sku_name = \"GP_Standard_D2ds_v5\" or another HA-capable SKU before enabling postgres_high_availability_enabled."
    }

    precondition {
      condition = (
        var.llm_openai_api_key != ""
        || contains(nonsensitive(keys(var.honcho_secret_env)), "LLM_OPENAI_API_KEY")
      )
      error_message = "Set llm_openai_api_key or honcho_secret_env.LLM_OPENAI_API_KEY before applying. Honcho's configured OpenAI-compatible LiteLLM models require this key at startup."
    }
  }
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${local.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  daily_quota_gb      = var.log_analytics_daily_quota_gb
  tags                = local.tags
}

resource "azurerm_container_app_environment" "main" {
  name                       = "cae-${local.name_prefix}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id   = azurerm_subnet.container_apps.id
  tags                       = local.tags

  lifecycle {
    ignore_changes = [workload_profile]
  }
}

resource "azurerm_user_assigned_identity" "container_apps" {
  name                = "id-${local.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.honcho.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

locals {
  redis_host = azapi_resource.redis.output.properties.hostName
  redis_key  = data.azapi_resource_action.redis_keys.output.primaryKey

  db_connection_uri = "postgresql+psycopg://${var.postgres_admin_username}:${urlencode(random_password.postgres.result)}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.honcho.name}?sslmode=require"
  redis_url         = "rediss://:${urlencode(local.redis_key)}@${local.redis_host}:10000/0?suppress=true"
  auth_jwt_secret   = coalesce(var.auth_jwt_secret, random_password.auth_jwt.result)
  deployment_revision = substr(sha256(join("|", [
    local.honcho_image,
    local.image_source_hash,
    sha256(nonsensitive(local.redis_key)),
    var.image_rebuild_token,
  ])), 0, 16)

  default_honcho_env = {
    LOG_LEVEL                   = "INFO"
    AUTH_USE_AUTH               = "true"
    CACHE_ENABLED               = "true"
    DB_POOL_SIZE                = tostring(var.db_pool_size)
    DB_MAX_OVERFLOW             = tostring(var.db_max_overflow)
    DB_POOL_PRE_PING            = "true"
    DB_POOL_USE_LIFO            = "true"
    EMBED_MESSAGES              = "true"
    VECTOR_STORE_TYPE           = "pgvector"
    VECTOR_STORE_MIGRATED       = "false"
    VECTOR_STORE_NAMESPACE      = "honcho"
    SENTRY_ENVIRONMENT          = var.environment
    TELEMETRY_ENABLED           = "false"
    METRICS_ENABLED             = "false"
    PYTHON_DOTENV_DISABLED      = "1"
    HONCHO_CONFIG_TOML_DISABLED = "1"
    HONCHO_DEPLOYMENT_REVISION  = local.deployment_revision
  }

  embedding_vector_dimensions_raw = lookup(var.honcho_env, "EMBEDDING_VECTOR_DIMENSIONS", "1536")
  embedding_vector_dimensions     = try(tonumber(local.embedding_vector_dimensions_raw), null)

  llm_secret_candidates = {
    LLM_OPENAI_API_KEY    = var.llm_openai_api_key
    LLM_ANTHROPIC_API_KEY = var.llm_anthropic_api_key
    LLM_GEMINI_API_KEY    = var.llm_gemini_api_key
  }

  llm_secret_env = {
    for key, value in local.llm_secret_candidates : key => value
    if nonsensitive(value) != ""
  }

  secret_env_values = merge(
    {
      DB_CONNECTION_URI = local.db_connection_uri
      CACHE_URL         = local.redis_url
      AUTH_JWT_SECRET   = local.auth_jwt_secret
    },
    local.llm_secret_env,
    var.honcho_secret_env,
  )

  secret_env = {
    for env_name in nonsensitive(keys(local.secret_env_values)) : env_name => {
      secret_name = substr(trim(replace(replace(lower(env_name), "__", "-"), "/[^a-z0-9-]/", "-"), "-"), 0, 63)
      value       = local.secret_env_values[env_name]
    }
  }
  secret_env_names = nonsensitive(toset(keys(local.secret_env)))

  honcho_env = {
    for key, value in merge(local.default_honcho_env, var.honcho_env) : key => value
    if !contains(nonsensitive(keys(local.secret_env_values)), key)
  }
}

resource "azurerm_container_app" "api" {
  name                         = local.api_app_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  registry {
    server   = azurerm_container_registry.honcho.login_server
    identity = azurerm_user_assigned_identity.container_apps.id
  }

  dynamic "secret" {
    for_each = local.secret_env_names

    content {
      name  = local.secret_env[secret.value].secret_name
      value = local.secret_env[secret.value].value
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 8000
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.api_min_replicas
    max_replicas = var.api_max_replicas

    container {
      name    = "api"
      image   = local.honcho_image
      cpu     = var.api_cpu
      memory  = var.api_memory
      command = ["/bin/sh", "-c", local.api_startup_command]

      dynamic "env" {
        for_each = local.honcho_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_names

        content {
          name        = env.value
          secret_name = local.secret_env[env.value].secret_name
        }
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 30
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/health"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_postgresql_flexible_server_database.honcho,
    azurerm_private_endpoint.redis,
    terraform_data.acr_build,
  ]
}

resource "azurerm_container_app" "deriver" {
  name                         = local.deriver_app_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  registry {
    server   = azurerm_container_registry.honcho.login_server
    identity = azurerm_user_assigned_identity.container_apps.id
  }

  dynamic "secret" {
    for_each = local.secret_env_names

    content {
      name  = local.secret_env[secret.value].secret_name
      value = local.secret_env[secret.value].value
    }
  }

  template {
    min_replicas = var.deriver_min_replicas
    max_replicas = var.deriver_max_replicas

    container {
      name    = "deriver"
      image   = local.honcho_image
      cpu     = var.deriver_cpu
      memory  = var.deriver_memory
      command = ["/bin/sh", "-c", local.deriver_startup_command]

      dynamic "env" {
        for_each = local.honcho_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env_names

        content {
          name        = env.value
          secret_name = local.secret_env[env.value].secret_name
        }
      }
    }
  }

  depends_on = [
    azurerm_container_app.api,
    azurerm_role_assignment.acr_pull,
    terraform_data.acr_build,
  ]
}
