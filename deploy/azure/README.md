# Honcho on Azure with OpenTofu

This folder provisions a production-oriented Honcho deployment on Azure:

- Azure Container Apps for the API and deriver worker.
- A separate Azure Container App for the Honcho MCP endpoint.
- Azure Database for PostgreSQL Flexible Server with private networking and the `vector` extension allowlisted for pgvector.
- Azure Managed Redis with TLS, public network access disabled, Private Link, and optional high availability.
- Azure Container Registry with managed-identity pulls and admin access disabled.
- Log Analytics for Container Apps logs.

The defaults are intentionally small. PostgreSQL defaults to `B_Standard_B1ms`
for the lowest viable baseline cost, with HA disabled; switch to an HA-capable
General Purpose SKU such as `GP_Standard_D2ds_v5` before enabling PostgreSQL HA.
Redis uses Azure Managed Redis instead of the older Azure Cache for Redis path.
Container Apps uses consumption compute to keep steady-state cost down.

For current default monthly estimates and the main cost-sensitive toggles, see [COST_ESTIMATE.md](COST_ESTIMATE.md).

## Prerequisites

- OpenTofu 1.8 or newer.
- Azure CLI logged into the target subscription.
- Permission to create resource groups, networking, Container Apps, ACR, PostgreSQL Flexible Server, Azure Managed Redis, private endpoints, and role assignments.
- An LLM provider key. With Honcho's built-in defaults, set `llm_openai_api_key`.

The default build path uses `az acr build`, so local Docker is not required.

## Deploy

```bash
cd deploy/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set llm_openai_api_key, location, and any overrides.

tofu init
tofu apply
```

By default, `tofu apply` creates ACR, uploads the repo as an ACR build context,
builds `honcho:<image_tag>`, and deploys both Container Apps with that image.
The API startup runs database migrations and then applies Honcho's embedding
schema configurator before traffic is served. Because this deployment uses
pgvector HNSW indexes, keep `EMBEDDING_VECTOR_DIMENSIONS` at 2000 or lower;
the included LiteLLM example uses `text-embedding-3-small` with the default
1536 dimensions.

If you already publish an image, set:

```hcl
container_image           = "myregistry.azurecr.io/honcho:2026-05-25"
build_image_with_acr_task = false
```

The MCP endpoint is built from `mcp/` into `honcho-mcp:<mcp_image_tag>` and
deployed as a separate Container App. It proxies to `mcp_honcho_api_url`, which
defaults to `https://honcho.llm.kia.dev` for this production deployment.

## MCP Custom Domain

The MCP custom domain defaults to `mcp.honcho.llm.kia.dev`. After the first
apply, get the required DNS records:

```bash
tofu output mcp_custom_domain_dns_records
```

Create those records in the public DNS zone, or let this stack manage them in
Cloudflare by setting:

```bash
export CLOUDFLARE_API_TOKEN=...
tofu apply \
  -var manage_mcp_dns_records=true \
  -var cloudflare_zone_id=...
```

After DNS has propagated, enable the managed certificate binding:

```bash
tofu apply -var enable_mcp_custom_domain_binding=true
```

The custom-domain binding uses Azure Container Apps managed certificates and
the CNAME validation flow.

## First Admin Key

Authentication is enabled by default. After apply, mint an admin JWT from the generated secret:

```bash
cd ../..
AUTH_USE_AUTH=true AUTH_JWT_SECRET="$(cd deploy/azure && tofu output -raw auth_jwt_secret)" \
  uv run python -c 'from src.security import create_admin_jwt; print(create_admin_jwt())'
```

Use that bearer token to call `/v3/keys` and create scoped workspace, peer, or session keys.

## Configuration

Use `terraform.tfvars` for deployment values. Use `.env.example` as the Honcho runtime configuration reference. Non-secret runtime overrides go in `honcho_env`; secret runtime overrides go in `honcho_secret_env`.

Example:

```hcl
honcho_env = {
  DERIVER_WORKERS = "2"
  DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL = "gpt-5.4-mini"
}

honcho_secret_env = {
  WEBHOOK_SECRET = "replace-me"
}
```

OpenTofu generates and injects `DB_CONNECTION_URI`, `CACHE_URL`, and `AUTH_JWT_SECRET` as Container App secrets.

## Hardening Notes

- PostgreSQL and Redis are private-only. The public API is protected by Honcho JWT auth.
- Redis uses TLS (`rediss://`) on port `10000`.
- ACR is public-authenticated by default so initial build/push works on ordinary workstations. For a fully private registry path, set `acr_sku = "Premium"`, set `acr_public_network_access_enabled = false`, and run builds from a network that can reach the registry private endpoint you add.
- PostgreSQL HA, Redis HA, and geo-redundant backups are off by default to control cost. Turn them on in `terraform.tfvars` for stricter production resilience. PostgreSQL HA also requires switching away from the default burstable `B_Standard_B1ms` SKU.
- Terraform/OpenTofu state contains generated secrets. Store state in a secured remote backend before using this for real production data.

## Useful Commands

```bash
tofu output -raw health_url
tofu output -raw manual_acr_build_command
az containerapp logs show \
  --resource-group "$(tofu output -raw resource_group_name)" \
  --name "$(tofu output -raw api_container_app_name)"
```

## Source References

This deployment follows the Honcho self-hosting guide's service shape: API, deriver, PostgreSQL with pgvector, Redis, migrations on API start, and env-driven LLM setup. It also follows the Honcho configuration guide's environment-variable mapping, including nested `__` keys for model configuration.

- https://honcho.dev/docs/v3/contributing/self-hosting
- https://honcho.dev/docs/v3/contributing/configuration
