# outputs.tf — Useful values after apply.

output "resource_group_name" {
  description = "Name of the resource group holding all StatusPage target-state resources."
  value       = azurerm_resource_group.main.name
}

output "statuspage_vm_name" {
  description = "Name of the StatusPage Windows Server 2022 virtual machine."
  value       = azurerm_windows_virtual_machine.statuspage.name
}

output "statuspage_vm_private_ip" {
  description = "Private IP address of the StatusPage VM (App Tier subnet)."
  value       = azurerm_network_interface.main.private_ip_address
}

output "application_gateway_public_ip" {
  description = "Public IP address of the Application Gateway (HAProxy replacement)."
  value       = azurerm_public_ip.appgw.ip_address
}



output "key_vault_uri" {
  description = "URI of the Key Vault holding the VM admin password and disk encryption key."
  value       = azurerm_key_vault.main.vault_uri
}

output "key_vault_name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.main.name
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics Workspace (Azure Monitor backing store)."
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace."
  value       = azurerm_log_analytics_workspace.main.name
}

output "storage_account_name" {
  description = "Name of the Storage Account used for diagnostics and artefact staging."
  value       = azurerm_storage_account.main.name
}

output "artefacts_container_name" {
  description = "Name of the blob container for statuspage.jar and WinSW artefacts."
  value       = azurerm_storage_container.artefacts.name
}

output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity attached to the VM."
  value       = azurerm_user_assigned_identity.statuspage.client_id
}

output "managed_identity_principal_id" {
  description = "Principal (object) ID of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.statuspage.principal_id
}

output "dns_zone_name_servers" {
  description = "Azure DNS name servers for the zone — delegate these at your registrar."
  value       = azurerm_dns_zone.main.name_servers
}

output "bastion_host_name" {
  description = "Name of the Azure Bastion host for secure VM access."
  value       = azurerm_bastion_host.main.name
}

output "statuspage_url" {
  description = "Public URL for the StatusPage application (via Front Door)."
  value       = "http://${azurerm_public_ip.appgw.ip_address}:8080"
}

output "statuspage_health_url" {
  description = "Health check URL for the StatusPage application."
  value       = "http://${azurerm_public_ip.appgw.ip_address}:8080/health"
}