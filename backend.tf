# backend.tf — Remote state configuration using Azure Blob Storage.
# The storage account and container must be pre-created (see README).
# State is encrypted at rest by Azure Storage Service Encryption (SSE)
# with a customer-managed key stored in Key Vault (configured separately).

terraform {
  backend "azurerm" {
    resource_group_name  = "statuspage-tfstate-rg"
    storage_account_name = "statuspageTfstate"   # must be globally unique — override in CI
    container_name       = "tfstate"
    key                  = "statuspage/prod/terraform.tfstate"
    # use_oidc = true  # Uncomment when running in Azure DevOps / GitHub Actions with OIDC
  }
}