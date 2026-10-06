# StatusPage — Azure Target-State Infrastructure

Terraform-managed infrastructure for the **StatusPage** Java REST API on Azure.

## Architecture Overview

```
End User
   │ DNS:53
   ▼
Azure DNS (statuspage.example.com)
   │ HTTPS:443
   ▼
Azure Front Door (edge CDN / TLS termination / global LB)
   │ HTTP:8080
   ▼
Azure Application Gateway WAF_v2 (replaces HAProxy / haproadba-app-007)
   │ HTTP:8080
   ▼
Windows Server 2022 VM — Standard_D4s_v5
  ├── Java 26 (Eclipse Temurin)
  ├── statuspage.jar (Maven build — GET / and GET /health on :8080)
  ├── WinSW Windows Service Wrapper (replaces Linux systemd)
  ├── Azure Monitor Agent → Log Analytics Workspace
  ├── Dynatrace OneAgent (external APM — API-key auth)
  ├── Nagios monitoring polls (HTTP:8080)
  └── OpenSSH for Windows (:22, management subnet only)

Management Access: Azure Bastion (no public RDP/SSH exposure)
Secrets: Azure Key Vault (CMK disk encryption + admin password)
Storage: Azure Blob Storage (artefact staging + diagnostic logs)
```

## Changes from Source State

| # | Change | Detail |
|---|--------|--------|
| 1 | **Runtime: Java 8 → Java 26** | Eclipse Temurin 26 installed via bootstrap; `pom.xml` compiler source/target updated to `26` |
| 2 | **Platform: Linux → Windows Server 2022** | Systemd service replaced by WinSW Windows Service Wrapper |

## Prerequisites

### 1. Azure CLI & Terraform

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Install Terraform >= 1.9
brew install hashicorp/tap/terraform   # macOS
# or download from https://developer.hashicorp.com/terraform/downloads
```

### 2. Authenticate to Azure

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# Verify
az account show
```

### 3. Create Remote State Backend Resources

Run this **once** before `terraform init`:

```bash
# Variables
LOCATION="eastus"
RG_NAME="statuspage-tfstate-rg"
SA_NAME="statuspageTfstate"   # must be globally unique — change if taken
CONTAINER_NAME="tfstate"

# Create resource group
az group create --name $RG_NAME --location $LOCATION

# Create storage account (LRS is fine for state; upgrade to GRS for prod)
az storage account create \
  --name $SA_NAME \
  --resource-group $RG_NAME \
  --location $LOCATION \
  --sku Standard_LRS \
  --encryption-services blob \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

# Create container
az storage container create \
  --name $CONTAINER_NAME \
  --account-name $SA_NAME \
  --auth-mode login

echo "Backend ready: $SA_NAME / $CONTAINER_NAME"
```

Update `backend.tf` with your actual `storage_account_name` if you changed `SA_NAME`.

### 4. Set Sensitive Variables

```bash
# Never pass the password on the command line — use an env var
export TF_VAR_admin_password='YourStr0ng!P@ssw0rd123'
```

## Deployment

### Step 1 — Initialise

```bash
terraform init
```

### Step 2 — Review the plan

```bash
terraform plan -var-file=terraform.tfvars
```

### Step 3 — Apply

```bash
terraform apply -var-file=terraform.tfvars
```

### Step 4 — Upload Application Artefacts

After the VM is provisioned, upload `statuspage.jar` and `winsw.exe` to the
artefacts blob container. The bootstrap script downloads them on first boot.

```bash
# Get storage account name from Terraform output
SA_NAME=$(terraform output -raw storage_account_name)

# Upload the Maven-built JAR (build with: mvn clean package -DskipTests)
az storage blob upload \
  --account-name $SA_NAME \
  --container-name artefacts \
  --name statuspage.jar \
  --file target/statuspage.jar \
  --auth-mode login

# Upload WinSW (download from https://github.com/winsw/winsw/releases)
az storage blob upload \
  --account-name $SA_NAME \
  --container-name artefacts \
  --name winsw.exe \
  --file WinSW-x64.exe \
  --auth-mode login
```

### Step 5 — Trigger Bootstrap (if VM already running)

If the VM was provisioned before artefacts were uploaded, trigger the
bootstrap script manually:

```bash
VM_NAME=$(terraform output -raw statuspage_vm_name)
RG_NAME=$(terraform output -raw resource_group_name)

az vm run-command invoke \
  --resource-group $RG_NAME \
  --name $VM_NAME \
  --command-id RunPowerShellScript \
  --scripts "C:\statuspage\bootstrap.log" \
  --output table
```

Or re-run the bootstrap:

```bash
az vm run-command invoke \
  --resource-group $RG_NAME \
  --name $VM_NAME \
  --command-id RunPowerShellScript \
  --scripts @scripts/bootstrap.ps1.tpl
```

### Step 6 — Delegate DNS

Point your domain registrar's nameservers to the Azure DNS name servers:

```bash
terraform output dns_zone_name_servers
```

### Step 7 — Verify

```bash
# Health check via Front Door
curl https://$(terraform output -raw front_door_endpoint_hostname)/health
# Expected: HTTP 200, body: OK

# Root endpoint
curl https://$(terraform output -raw front_door_endpoint_hostname)/
# Expected: HTTP 200, HTML with "StatusPage is running"
```

## pom.xml Changes (Java 8 → Java 26)

Update your `pom.xml` compiler configuration:

```xml
<properties>
    <!-- Change 1: Java 8 → Java 26 -->
    <maven.compiler.source>26</maven.compiler.source>
    <maven.compiler.target>26</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
</properties>

<build>
    <plugins>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-compiler-plugin</artifactId>
            <version>3.13.0</version>
            <configuration>
                <source>26</source>
                <target>26</target>
                <!-- Enable preview features if needed for Java 26 -->
                <!-- <compilerArgs><arg>--enable-preview</arg></compilerArgs> -->
            </configuration>
        </plugin>
        <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-jar-plugin</artifactId>
            <version>3.4.2</version>
            <configuration>
                <archive>
                    <manifest>
                        <mainClass>com.statuspage.Main</mainClass>
                    </manifest>
                </archive>
                <finalName>statuspage</finalName>
            </configuration>
        </plugin>
    </plugins>
</build>
```

Build command:
```bash
mvn clean package -DskipTests
# Output: target/statuspage.jar
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `location` | Azure region | `string` | `"East US"` | no |
| `environment` | Environment label | `string` | `"dev"` | no |
| `owner` | Owning team | `string` | `"platform-team"` | no |
| `cost_center` | Billing cost centre | `string` | `"CC-STATUSPAGE"` | no |
| `vnet_address_space` | VNet CIDR | `string` | `"10.0.0.0/16"` | no |
| `app_subnet_cidr` | App tier subnet CIDR | `string` | `"10.0.1.0/24"` | no |
| `appgw_subnet_cidr` | App Gateway subnet CIDR | `string` | `"10.0.2.0/24"` | no |
| `management_subnet_cidr` | Bastion subnet CIDR | `string` | `"10.0.3.0/26"` | no |
| `nagios_source_cidr` | Nagios host CIDR | `string` | `"10.0.0.0/16"` | no |
| `dynatrace_source_cidr` | Dynatrace host CIDR | `string` | `"10.0.0.0/16"` | no |
| `allowed_ip_ranges` | IPs for KV/Storage access | `list(string)` | `[]` | no |
| `vm_size` | VM SKU | `string` | `"Standard_D4s_v5"` | no |
| `admin_username` | VM admin username | `string` | `"statuspageadmin"` | no |
| `admin_password` | VM admin password | `string` | — | **yes** |
| `app_port` | Application HTTP port | `number` | `8080` | no |
| `java_version` | Java version to install | `string` | `"26"` | no |
| `log_retention_days` | Log Analytics retention | `number` | `90` | no |
| `alert_email_addresses` | Alert notification emails | `list(string)` | `[]` | no |
| `dns_zone_name` | Azure DNS zone | `string` | `"statuspage.example.com"` | no |
| `dns_record_name` | DNS record name | `string` | `"@"` | no |

## Outputs

| Name | Description |
|------|-------------|
| `resource_group_name` | Resource group name |
| `statuspage_vm_name` | VM name |
| `statuspage_vm_private_ip` | VM private IP |
| `application_gateway_public_ip` | App Gateway public IP |
| `front_door_endpoint_hostname` | Front Door hostname |
| `key_vault_uri` | Key Vault URI |
| `log_analytics_workspace_id` | Log Analytics resource ID |
| `storage_account_name` | Storage account name |
| `managed_identity_client_id` | Managed identity client ID |
| `dns_zone_name_servers` | Azure DNS name servers |
| `statuspage_url` | Public HTTPS URL |
| `statuspage_health_url` | Health check URL |

## Security Notes

- **No public IP on the VM** — access only via Azure Bastion (RDP/SSH) or App Gateway (HTTP:8080)
- **CMK disk encryption** — OS disk encrypted with a customer-managed key in Key Vault
- **Managed Identity** — VM authenticates to Azure Monitor, Key Vault, and Storage without stored credentials
- **WAF** — Application Gateway runs in WAF_v2 Prevention mode with OWASP 3.2 ruleset
- **TLS** — Front Door terminates TLS; HTTP→HTTPS redirect enforced at the edge
- **Key Vault** — network-restricted to VNet subnets and `allowed_ip_ranges`
- **Storage** — public blob access disabled; HTTPS-only; TLS 1.2 minimum

## Dependency Mapping

| Source Dependency | Azure Equivalent | Score | Status |
|-------------------|-----------------|-------|--------|
| HAProxy (haproadba-app-007:8080) | Azure Application Gateway WAF_v2 | 8/10 | ✅ Provisioned |
| Dynatrace APM (dynaapm-app2-096:8080) | External SaaS — NSG rule + bootstrap install | 7/10 | ✅ NSG rule provisioned |
| Nagios Monitoring (nagimoni-app-049:8080) | External — NSG rule allows polls | 7/10 | ✅ NSG rule provisioned |
| Nessus Agent (local) | Local agent — bootstrap script (optional) | 4/10 | ⚠️ Optional / commented |
| Chrony / NTP | Windows Time Service (W32tm) — built-in | 3/10 | ⏭️ Skipped (built-in) |
| OpenSSH | OpenSSH for Windows — NSG rule :22 | 2/10 | ✅ NSG rule (trivial) |

## Destroy

```bash
terraform destroy -var-file=terraform.tfvars
```

> ⚠️ This will delete all resources including the Key Vault (soft-delete
> protects secrets for 90 days). The remote state backend resources
> (`statuspage-tfstate-rg`) are **not** managed by this configuration and
> must be deleted manually if desired.