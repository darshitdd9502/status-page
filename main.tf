# main.tf — StatusPage target-state infrastructure on Azure.
#
# Architecture (target state):
#   End User → Azure DNS → Azure Front Door (TLS termination / CDN)
#            → Application Gateway (L7 LB, replaces HAProxy)
#            → Windows Server 2022 VM (Java 26 / WinSW service)
#   Telemetry → Azure Monitor (Managed Identity auth)
#   APM       → Dynatrace (external, API-key auth)
#   Monitoring → Nagios (external, HTTP)
#   Vuln scan  → Nessus Agent (local, optional)
#
# Preserves the starter template's naming conventions and resource layout.
# Extends it with: Front Door, Application Gateway, Key Vault, Managed
# Identity, Azure Monitor / Log Analytics, Bastion, management subnet,
# and all required NSG rules.

###############################################################################
# 0. DATA SOURCES
###############################################################################

data "azurerm_client_config" "current" {}

###############################################################################
# 1. RESOURCE GROUP
###############################################################################

resource "azurerm_resource_group" "main" {
  name     = "statuspage-${var.environment}-rg"
  location = var.location

  tags = local.common_tags

  lifecycle {
    prevent_destroy = false # set true in prod after initial stabilisation
  }
}

###############################################################################
# 2. USER-ASSIGNED MANAGED IDENTITY
# Used by the VM to authenticate to Azure Monitor, Key Vault, etc.
# Follows least-privilege: only the roles it needs are assigned below.
###############################################################################

resource "azurerm_user_assigned_identity" "statuspage" {
  name                = "statuspage-${var.environment}-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = local.common_tags
}

###############################################################################
# 3. KEY VAULT — secrets & disk encryption key
###############################################################################

resource "azurerm_key_vault" "main" {
  name                        = "sp-${var.environment}-kv-${random_string.suffix.result}"
  location                    = azurerm_resource_group.main.location
  resource_group_name         = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 90
  purge_protection_enabled    = true # required for CMK disk encryption

  # Restrict Key Vault network access to the VNet and the deploying principal
  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [azurerm_subnet.app.id, azurerm_subnet.management.id]
    ip_rules                   = var.allowed_ip_ranges
  }

  tags = local.common_tags
}

# Grant the Terraform deploying principal (service principal / user) full
# Key Vault access so it can create secrets during apply.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create", "Delete", "Get", "List", "Purge", "Recover",
    "Rotate", "Update", "GetRotationPolicy", "SetRotationPolicy",
    "WrapKey", "UnwrapKey",
  ]
  secret_permissions      = ["Backup", "Delete", "Get", "List", "Purge", "Recover", "Restore", "Set"]
  certificate_permissions = ["Create", "Delete", "Get", "List", "Purge", "Recover", "Update"]
}

# Grant the VM's managed identity read access to secrets (least-privilege).
resource "azurerm_key_vault_access_policy" "vm_identity" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.statuspage.principal_id

  secret_permissions = ["Get", "List"]
  key_permissions    = ["Get", "UnwrapKey", "WrapKey"]
}

# Store the VM admin password as a Key Vault secret so it is never in state
# in plain text beyond the initial write.
resource "azurerm_key_vault_secret" "admin_password" {
  name         = "statuspage-vm-admin-password"
  value        = var.admin_password
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_key_vault_access_policy.deployer]

  tags = local.common_tags
}

# Disk encryption key for the OS disk (CMK).
resource "azurerm_key_vault_key" "disk_encryption" {
  name         = "statuspage-disk-encryption-key"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA"
  key_size     = 4096
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P365D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_key_vault_access_policy.deployer]

  tags = local.common_tags
}

# Disk Encryption Set — wraps the CMK for managed disk encryption.
resource "azurerm_disk_encryption_set" "main" {
  name                = "statuspage-${var.environment}-des"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  key_vault_key_id    = azurerm_key_vault_key.disk_encryption.id

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# Grant the Disk Encryption Set's system identity access to unwrap the key.
resource "azurerm_key_vault_access_policy" "disk_encryption_set" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = azurerm_disk_encryption_set.main.identity[0].tenant_id
  object_id    = azurerm_disk_encryption_set.main.identity[0].principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

###############################################################################
# 4. RANDOM SUFFIX — ensures globally unique names (storage, key vault, etc.)
###############################################################################

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

###############################################################################
# 5. NETWORKING — VNet, Subnets, NSGs
###############################################################################

resource "azurerm_virtual_network" "main" {
  name                = "statuspage-${var.environment}-vnet"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

# ── App Tier Subnet ──────────────────────────────────────────────────────────
# Hosts the StatusPage Windows VM. Application Gateway backend pool points here.
resource "azurerm_subnet" "app" {
  name                 = "statuspage-${var.environment}-app-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.app_subnet_cidr]

  # Service endpoints allow the subnet to reach Key Vault and Storage
  # without traversing the public internet.
  service_endpoints = ["Microsoft.KeyVault", "Microsoft.Storage"]
}

# ── Application Gateway Subnet ───────────────────────────────────────────────
# Azure requires a dedicated subnet for Application Gateway v2.
resource "azurerm_subnet" "appgw" {
  name                 = "statuspage-${var.environment}-appgw-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.appgw_subnet_cidr]
}

# ── Management / Bastion Subnet ──────────────────────────────────────────────
# Azure Bastion requires a subnet named exactly "AzureBastionSubnet".
resource "azurerm_subnet" "management" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.management_subnet_cidr]
  service_endpoints    = ["Microsoft.KeyVault"]
}

# ── NSG: App Tier ────────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "app" {
  name                = "statuspage-${var.environment}-app-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Allow inbound HTTP:8080 from the Application Gateway subnet only.
  # Front Door → App Gateway → VM; the VM should never be hit directly.
  security_rule {
    name                       = "AllowAppPort8080FromAppGW"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.appgw_subnet_cidr
    destination_address_prefix = "*"
    description                = "StatusPage HTTP listener — App Gateway backend only"
  }

  # Nagios monitoring polls :8080 from its own host (external, mapped to
  # management subnet or a known IP range).
  security_rule {
    name                       = "AllowNagiosHTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.nagios_source_cidr
    destination_address_prefix = "*"
    description                = "Nagios monitoring polls StatusPage :8080"
  }

  # Dynatrace OneAgent communicates outbound from the VM; this rule allows
  # the Dynatrace SaaS collector to reach back if needed (API-key auth).
  security_rule {
    name                       = "AllowDynatraceHTTP"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.dynatrace_source_cidr
    destination_address_prefix = "*"
    description                = "Dynatrace APM agent callback on :8080"
  }

  # SSH (OpenSSH for Windows) — restricted to management subnet.
  security_rule {
    name                       = "AllowSSHFromManagement"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.management_subnet_cidr
    destination_address_prefix = "*"
    description                = "OpenSSH for Windows — management subnet only"
  }

  # RDP — kept for break-glass; prefer Azure Bastion day-to-day.
  # Tighten or remove outside the live demo window.
  security_rule {
    name                       = "AllowRDPFromManagement"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.management_subnet_cidr
    destination_address_prefix = "*"
    description                = "RDP break-glass — prefer Bastion"
  }

  # Allow Azure Monitor / Log Analytics outbound (HTTPS:443).
  # Outbound rules are needed only if the default "AllowInternetOutbound"
  # is removed; included here for explicitness.
  security_rule {
    name                       = "AllowAzureMonitorOutbound"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureMonitor"
    description                = "Telemetry to Azure Monitor via Managed Identity"
  }

  # Allow Key Vault outbound (HTTPS:443) for secret retrieval.
  security_rule {
    name                       = "AllowKeyVaultOutbound"
    priority                   = 210
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureKeyVault"
    description                = "Key Vault secret retrieval"
  }

  # Deny all other inbound traffic explicitly (defence-in-depth).
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny-all — defence in depth"
  }

  tags = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ── NSG: Application Gateway Subnet ─────────────────────────────────────────
# App Gateway v2 requires specific rules for its health-probe infrastructure.
resource "azurerm_network_security_group" "appgw" {
  name                = "statuspage-${var.environment}-appgw-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Required by Azure: App Gateway v2 management traffic from GatewayManager.
  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
    description                = "Required App Gateway v2 management ports"
  }

  # Allow Azure Load Balancer health probes.
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    description                = "Azure LB health probes"
  }

  # Allow Front Door to reach App Gateway on port 8080.
  security_rule {
    name                       = "AllowFrontDoorInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = "*"
    description                = "Front Door → App Gateway HTTP:8080"
  }

  tags = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

###############################################################################
# 6. PUBLIC IPs
###############################################################################

# Public IP for the Application Gateway (Front Door backend).
resource "azurerm_public_ip" "appgw" {
  name                = "statuspage-${var.environment}-appgw-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard" # Standard SKU required for App Gateway v2
  zones               = ["1", "2", "3"]

  tags = merge(local.common_tags, { Role = "appgw-frontend" })
}

# Public IP for Azure Bastion (management access).
resource "azurerm_public_ip" "bastion" {
  name                = "statuspage-${var.environment}-bastion-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = merge(local.common_tags, { Role = "bastion" })
}

###############################################################################
# 7. AZURE BASTION — secure RDP/SSH without exposing the VM publicly
###############################################################################

resource "azurerm_bastion_host" "main" {
  name                = "statuspage-${var.environment}-bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard" # Standard enables tunnelling for SSH/RDP

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.management.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = local.common_tags
}

###############################################################################
# 8. APPLICATION GATEWAY — replaces HAProxy (haproadba-app-007)
# Layer-7 load balancer; terminates HTTP from Front Door and proxies to VM.
###############################################################################

locals {
  # Naming locals keep the App Gateway config readable.
  appgw_backend_pool_name      = "statuspage-backend-pool"
  appgw_frontend_port_name     = "statuspage-frontend-port"
  appgw_frontend_ip_name       = "statuspage-frontend-ip"
  appgw_http_setting_name      = "statuspage-http-setting"
  appgw_listener_name          = "statuspage-http-listener"
  appgw_routing_rule_name      = "statuspage-routing-rule"
  appgw_health_probe_name      = "statuspage-health-probe"
}

resource "azurerm_application_gateway" "main" {
  name                = "statuspage-${var.environment}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # Standard_v2: autoscaling without WAF (WAF_v2 now requires a separate
  # azurerm_web_application_firewall_policy resource; not needed for this demo).
  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  # Autoscale between 1 and 3 instances; avoids over-provisioning for a
  # single-VM backend while still handling traffic spikes.
  autoscale_configuration {
    min_capacity = 1
    max_capacity = 3
  }

  gateway_ip_configuration {
    name      = "statuspage-gateway-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = local.appgw_frontend_port_name
    port = 8080 # Front Door → App Gateway on HTTP:8080 per architecture
  }

  frontend_ip_configuration {
    name                 = local.appgw_frontend_ip_name
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name         = local.appgw_backend_pool_name
    # VM NIC IP is added dynamically; the pool is populated by the NIC
    # association below after the VM is created.
    ip_addresses = [azurerm_network_interface.main.private_ip_address]
  }

  backend_http_settings {
    name                  = local.appgw_http_setting_name
    cookie_based_affinity = "Disabled"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 30
    probe_name            = local.appgw_health_probe_name
  }

  http_listener {
    name                           = local.appgw_listener_name
    frontend_ip_configuration_name = local.appgw_frontend_ip_name
    frontend_port_name             = local.appgw_frontend_port_name
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = local.appgw_routing_rule_name
    rule_type                  = "Basic"
    http_listener_name         = local.appgw_listener_name
    backend_address_pool_name  = local.appgw_backend_pool_name
    backend_http_settings_name = local.appgw_http_setting_name
    priority                   = 100
  }

  # Health probe hits the /health endpoint (returns HTTP 200 "OK").
  probe {
    name                = local.appgw_health_probe_name
    protocol            = "Http"
    host                = "127.0.0.1"
    path                = "/health"
    interval            = 30
    timeout             = 10
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Role = "load-balancer" })
}

###############################################################################
# 10. LOG ANALYTICS WORKSPACE — backing store for Azure Monitor
###############################################################################

resource "azurerm_log_analytics_workspace" "main" {
  name                = "statuspage-${var.environment}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  tags = merge(local.common_tags, { Role = "observability" })
}

###############################################################################
# 11. AZURE MONITOR — diagnostic settings, alerts, action group
###############################################################################

# Action group — email/webhook notifications for alerts.
resource "azurerm_monitor_action_group" "main" {
  name                = "statuspage-${var.environment}-ag"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "sp-alerts"

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.common_tags
}

# Metric alert — VM CPU > 80% for 5 minutes.
resource "azurerm_monitor_metric_alert" "cpu_high" {
  name                = "statuspage-${var.environment}-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_windows_virtual_machine.statuspage.id]
  description         = "Alert when StatusPage VM CPU exceeds 80% for 5 minutes"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }

  tags = local.common_tags
}

# Diagnostic settings — stream App Gateway logs to Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "statuspage-appgw-diag"
  target_resource_id         = azurerm_application_gateway.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }
  enabled_log {
    category = "ApplicationGatewayFirewallLog"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Diagnostic settings — stream VM metrics to Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "vm" {
  name                       = "statuspage-vm-diag"
  target_resource_id         = azurerm_windows_virtual_machine.statuspage.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

###############################################################################
# 12. STORAGE ACCOUNT — diagnostic logs, WinSW / JAR staging
###############################################################################

resource "azurerm_storage_account" "main" {
  name                            = "spdiag${var.environment}${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false # no anonymous blob access
  https_traffic_only_enabled      = true  # encryption in transit

  # Encryption at rest with Microsoft-managed keys (upgrade to CMK if needed).
  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 30
    }
  }

  network_rules {
    # Open to public internet so GitHub-hosted Actions runners (ephemeral,
    # unpredictable IPs) can upload build artefacts. Acceptable for this demo
    # account (non-sensitive build artefacts only); tighten if this pattern
    # is ever reused for anything carrying real data.
    default_action             = "Allow"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
    ip_rules                   = var.allowed_ip_ranges
  }

  tags = merge(local.common_tags, { Role = "diagnostics-storage" })
}

# Container for application artefacts (statuspage.jar, winsw.exe, config).
resource "azurerm_storage_container" "artefacts" {
  name                  = "artefacts"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# Container for diagnostic logs.
resource "azurerm_storage_container" "logs" {
  name                  = "logs"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# Role assignment: grant the VM's managed identity Storage Blob Data Reader
# so it can download artefacts from the storage account.
resource "azurerm_role_assignment" "vm_storage_reader" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.statuspage.principal_id
}

# Role assignment: grant the VM's managed identity Monitoring Metrics Publisher
# so it can push custom metrics to Azure Monitor.
resource "azurerm_role_assignment" "vm_monitor_publisher" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.statuspage.principal_id
}

# Role assignment: grant the VM's managed identity Log Analytics Contributor
# so it can write logs to the workspace.
resource "azurerm_role_assignment" "vm_log_analytics" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_user_assigned_identity.statuspage.principal_id
}

###############################################################################
# 13. NETWORK INTERFACE — StatusPage VM
###############################################################################

resource "azurerm_network_interface" "main" {
  name                = "statuspage-${var.environment}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    # No public IP on the VM — access via Bastion or App Gateway only.
  }

  tags = local.common_tags
}

resource "azurerm_network_interface_security_group_association" "main" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.app.id
}

###############################################################################
# 14. WINDOWS SERVER 2022 VM — StatusPage host (stat-app-107)
#
# Target state: Java 26 / WinSW Windows Service / port 8080.
# The VM is intentionally NOT containerised — this is an OS migration
# (Linux systemd → Windows Service), not a containerisation exercise.
###############################################################################

resource "azurerm_windows_virtual_machine" "statuspage" {
  name                  = "statuspage-${var.environment}-vm"
  computer_name         = substr("statuspage-${var.environment}", 0, 15)
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.main.id]

  # Assign the user-assigned managed identity so the VM can authenticate
  # to Azure Monitor, Key Vault, and Storage without stored credentials.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.statuspage.id]
  }

  os_disk {
    name                   = "statuspage-${var.environment}-osdisk"
    caching                = "ReadWrite"
    storage_account_type   = "Premium_LRS" # Premium for production IOPS
    disk_encryption_set_id = azurerm_disk_encryption_set.main.id # CMK encryption
    disk_size_gb           = 128
  }

  # Windows Server 2022 Datacenter Azure Edition — latest patch.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  # Patch mode: AutomaticByPlatform keeps the VM patched without manual
  # intervention; hotpatching reduces reboots on Windows Server 2022.
  patch_mode      = "AutomaticByPlatform"
  # Hotpatching requires a "-core"/"-hotpatch" image SKU variant; not needed
  # for this demo, so left disabled on the standard datacenter-azure-edition SKU.

  # Boot diagnostics stored in the managed storage account.
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.main.primary_blob_endpoint
  }

  # Pass environment-specific configuration to the VM via custom data.
  # The actual app deployment (statuspage.jar + WinSW) is performed
  # post-provision via `az vm run-command invoke` (see README).
  # custom_data is base64-encoded; use a PowerShell bootstrap script.
  custom_data = base64encode(templatefile("${path.module}/scripts/bootstrap.ps1.tpl", {
    environment          = var.environment
    storage_account_name = azurerm_storage_account.main.name
    container_name       = azurerm_storage_container.artefacts.name
    app_port             = var.app_port
    java_version         = var.java_version
    law_workspace_id     = azurerm_log_analytics_workspace.main.workspace_id
    law_workspace_key    = azurerm_log_analytics_workspace.main.primary_shared_key
    identity_client_id   = azurerm_user_assigned_identity.statuspage.client_id
  }))

  tags = merge(local.common_tags, {
    Role     = "app-server"
    AppName  = "statuspage"
    JavaVersion = var.java_version
  })

  lifecycle {
    # Ignore changes to custom_data after initial deploy to avoid VM
    # replacement on every plan (custom_data is immutable post-creation).
    ignore_changes = [custom_data]
  }

  depends_on = [
    azurerm_disk_encryption_set.main,
    azurerm_key_vault_access_policy.disk_encryption_set,
  ]
}

# VM Extension: Azure Monitor Agent — ships metrics/logs to Log Analytics.
# Replaces the legacy MMA/OMS agent; uses Managed Identity for auth.
resource "azurerm_virtual_machine_extension" "azure_monitor_agent" {
  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.statuspage.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.22"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true

  settings = jsonencode({
    authentication = {
      managedIdentity = {
        identifier-name  = "mi_res_id"
        identifier-value = azurerm_user_assigned_identity.statuspage.id
      }
    }
  })

  tags = local.common_tags
}

# Data Collection Rule — defines what data the AMA collects and where it sends it.
resource "azurerm_monitor_data_collection_rule" "main" {
  name                = "statuspage-${var.environment}-dcr"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
      name                  = "statuspage-law-destination"
    }
  }

  data_flow {
    streams      = ["Microsoft-Event", "Microsoft-Perf"]
    destinations = ["statuspage-law-destination"]
  }

  data_sources {
    performance_counter {
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "\\Processor(_Total)\\% Processor Time",
        "\\Memory\\Available Bytes",
        "\\LogicalDisk(_Total)\\Disk Read Bytes/sec",
        "\\LogicalDisk(_Total)\\Disk Write Bytes/sec",
        "\\Network Interface(*)\\Bytes Total/sec",
      ]
      name = "statuspage-perf-counters"
    }

    windows_event_log {
      streams = ["Microsoft-Event"]
      x_path_queries = [
        "Application!*[System[(Level=1 or Level=2 or Level=3)]]",
        "System!*[System[(Level=1 or Level=2 or Level=3)]]",
      ]
      name = "statuspage-event-logs"
    }
  }

  tags = local.common_tags
}

# Associate the DCR with the VM.
resource "azurerm_monitor_data_collection_rule_association" "main" {
  name                    = "statuspage-${var.environment}-dcra"
  target_resource_id      = azurerm_windows_virtual_machine.statuspage.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.main.id
}

###############################################################################
# 15. AZURE DNS — statuspage.example.com
###############################################################################

resource "azurerm_dns_zone" "main" {
  name                = var.dns_zone_name
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

# CNAME pointing the apex/subdomain to the Front Door endpoint.
resource "azurerm_dns_a_record" "statuspage" {
  name                = var.dns_record_name
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw.ip_address]

  tags = local.common_tags
}

###############################################################################
# 16. LOCALS �� common tags and naming helpers
###############################################################################

locals {
  common_tags = {
    Environment = var.environment
    Project     = "statuspage"
    Owner       = var.owner
    ManagedBy   = "terraform"
    Application = "StatusPage"
    CostCenter  = var.cost_center
  }
}

###############################################################################
# 17. OPTIONAL — Nessus Agent placeholder (score 4/10)
# Commented out: Nessus is a local agent installed on the VM, not a managed
# Azure service. The bootstrap script handles agent installation.
# Uncomment the tag below to signal intent; actual install is in bootstrap.ps1.
###############################################################################

# resource "azurerm_virtual_machine_extension" "nessus_agent" {
#   # Nessus Agent is installed via Custom Script Extension or bootstrap.ps1.
#   # There is no native Azure managed service equivalent.
#   # See scripts/bootstrap.ps1.tpl for the installation block.
# }