# terraform.tfvars — Example values for development environment.
# Copy to terraform.tfvars and fill in real values before running apply.
# NEVER commit sensitive values (admin_password) to source control.
# Use TF_VAR_admin_password environment variable instead.

###############################################################################
# CORE
###############################################################################
location    = "East US"
environment = "dev"
owner       = "platform-team"
cost_center = "CC-STATUSPAGE"

###############################################################################
# NETWORKING
###############################################################################
vnet_address_space     = "10.0.0.0/16"
app_subnet_cidr        = "10.0.1.0/24"
appgw_subnet_cidr      = "10.0.2.0/24"
management_subnet_cidr = "10.0.3.0/26"

# Restrict Nagios and Dynatrace source CIDRs to their actual host IPs in prod.
nagios_source_cidr    = "10.0.0.0/16"
dynatrace_source_cidr = "10.0.0.0/16"

# Add your CI/CD runner or office IP here so Key Vault / Storage are reachable
# during terraform apply. Example: ["203.0.113.10/32"]
allowed_ip_ranges = []

###############################################################################
# VIRTUAL MACHINE
###############################################################################
vm_size        = "Standard_D4s_v5"   # matches target-state architecture spec
admin_username = "statuspageadmin"
# admin_password — set via: export TF_VAR_admin_password='YourStr0ng!Pass'
app_port     = 8080
java_version = "26"   # Change 1: Java 8 → Java 26

###############################################################################
# OBSERVABILITY
###############################################################################
log_retention_days    = 90
alert_email_addresses = ["ops-team@example.com"]

###############################################################################
# DNS
###############################################################################
dns_zone_name   = "statuspage.example.com"
dns_record_name = "@"