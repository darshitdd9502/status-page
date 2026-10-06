# variables.tf — All input variables with descriptions, types, and validation.

###############################################################################
# CORE / LOCATION
###############################################################################

variable "location" {
  description = "Azure region to deploy all resources into (e.g. 'East US', 'West Europe')."
  type        = string
  default     = "East US"

  validation {
    condition = contains([
      "East US", "East US 2", "West US", "West US 2", "West US 3",
      "Central US", "North Central US", "South Central US",
      "West Europe", "North Europe", "UK South", "UK West",
      "Australia East", "Southeast Asia", "East Asia",
    ], var.location)
    error_message = "Location must be a valid Azure region string."
  }
}

variable "environment" {
  description = "Deployment environment label (e.g. 'prod', 'staging', 'dev'). Used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["prod", "staging", "dev", "test"], var.environment)
    error_message = "Environment must be one of: prod, staging, dev, test."
  }
}

variable "owner" {
  description = "Team or individual responsible for these resources. Used in the Owner tag."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost centre code for billing attribution. Used in the CostCenter tag."
  type        = string
  default     = "CC-STATUSPAGE"
}

###############################################################################
# NETWORKING
###############################################################################

variable "vnet_address_space" {
  description = "CIDR block for the StatusPage Virtual Network."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vnet_address_space))
    error_message = "vnet_address_space must be a valid CIDR block."
  }
}

variable "app_subnet_cidr" {
  description = "CIDR block for the App Tier subnet (hosts the StatusPage VM)."
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrnetmask(var.app_subnet_cidr))
    error_message = "app_subnet_cidr must be a valid CIDR block."
  }
}

variable "appgw_subnet_cidr" {
  description = "CIDR block for the Application Gateway dedicated subnet."
  type        = string
  default     = "10.0.2.0/24"

  validation {
    condition     = can(cidrnetmask(var.appgw_subnet_cidr))
    error_message = "appgw_subnet_cidr must be a valid CIDR block."
  }
}

variable "management_subnet_cidr" {
  description = "CIDR block for the Management / Azure Bastion subnet (must be /26 or larger for Bastion)."
  type        = string
  default     = "10.0.3.0/26"

  validation {
    condition     = can(cidrnetmask(var.management_subnet_cidr))
    error_message = "management_subnet_cidr must be a valid CIDR block."
  }
}

variable "nagios_source_cidr" {
  description = "CIDR or IP of the Nagios monitoring host (nagimoni-app-049). Allows :8080 inbound polls."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.nagios_source_cidr))
    error_message = "nagios_source_cidr must be a valid CIDR block."
  }
}

variable "dynatrace_source_cidr" {
  description = "CIDR or IP of the Dynatrace APM collector (dynaapm-app2-096). Allows :8080 inbound."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.dynatrace_source_cidr))
    error_message = "dynatrace_source_cidr must be a valid CIDR block."
  }
}

variable "allowed_ip_ranges" {
  description = "List of public IP ranges allowed to reach Key Vault and Storage Account (e.g. your CI/CD runner IPs)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for ip in var.allowed_ip_ranges : can(cidrnetmask(ip))])
    error_message = "All entries in allowed_ip_ranges must be valid CIDR blocks."
  }
}

###############################################################################
# VIRTUAL MACHINE
###############################################################################

variable "vm_size" {
  description = "Azure VM SKU for the StatusPage Windows host. Target state specifies Standard_D4s_v5."
  type        = string
  default     = "Standard_D4s_v5"

  validation {
    condition     = can(regex("^Standard_", var.vm_size))
    error_message = "vm_size must be a valid Azure VM SKU starting with 'Standard_'."
  }
}

variable "admin_username" {
  description = "Local administrator username for the Windows VM. Must not be 'administrator' or 'admin'."
  type        = string
  default     = "statuspageadmin"

  validation {
    condition     = !contains(["administrator", "admin", "root", "guest"], lower(var.admin_username))
    error_message = "admin_username must not be a reserved Windows username (administrator, admin, root, guest)."
  }
}

variable "admin_password" {
  description = <<-EOT
    Local administrator password for the Windows VM.
    Must be 12–123 characters and include 3 of: uppercase, lowercase, digit, symbol.
    Pass via TF_VAR_admin_password environment variable — never on the command line.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 123
    error_message = "admin_password must be between 12 and 123 characters."
  }
}

variable "app_port" {
  description = "HTTP port the StatusPage Java application listens on. Default 8080; overridable via PORT env var."
  type        = number
  default     = 8080

  validation {
    condition     = var.app_port > 1024 && var.app_port < 65535
    error_message = "app_port must be a valid unprivileged port (1025–65534)."
  }
}

variable "java_version" {
  description = "Java version to install on the Windows VM. Target state is Java 26."
  type        = string
  default     = "26"

  validation {
    condition     = contains(["21", "22", "23", "24", "25", "26"], var.java_version)
    error_message = "java_version must be a supported modern Java LTS or current release (21–26)."
  }
}

###############################################################################
# OBSERVABILITY
###############################################################################

variable "log_retention_days" {
  description = "Number of days to retain logs in the Log Analytics Workspace."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "alert_email_addresses" {
  description = "List of email addresses to notify when Azure Monitor alerts fire."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_email_addresses : can(regex("^[^@]+@[^@]+\\.[^@]+$", e))])
    error_message = "All entries in alert_email_addresses must be valid email addresses."
  }
}

###############################################################################
# DNS
###############################################################################

variable "dns_zone_name" {
  description = "Azure DNS zone name (e.g. 'statuspage.example.com')."
  type        = string
  default     = "statuspage.example.com"
}

variable "dns_record_name" {
  description = "DNS record name within the zone (e.g. '@' for apex, 'www' for subdomain)."
  type        = string
  default     = "@"
}