# bootstrap.ps1.tpl — PowerShell bootstrap script for the StatusPage Windows VM.
# Rendered by Terraform templatefile() and passed as custom_data (base64).
# Runs once on first boot via the Windows VM Agent.
#
# Responsibilities:
#   1. Install Java ${java_version} (Eclipse Temurin / Adoptium)
#   2. Download statuspage.jar and WinSW from Azure Blob Storage
#      (authenticated via Managed Identity — no stored credentials)
#   3. Install and start the StatusPage Windows Service via WinSW
#   4. Install and configure the Azure Monitor Agent (AMA)
#   5. (Optional) Install Nessus Agent — see commented block below
#
# NOTE: The actual statuspage.jar must be uploaded to the artefacts container
# before or immediately after VM provisioning. See README for the upload command.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

###############################################################################
# 0. LOGGING HELPER
###############################################################################
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$ts] $Message"
    Add-Content -Path "C:\statuspage\bootstrap.log" -Value "[$ts] $Message"
}

New-Item -ItemType Directory -Force -Path "C:\statuspage" | Out-Null
Write-Log "Bootstrap started — environment: ${environment}, Java: ${java_version}"

###############################################################################
# 1. INSTALL JAVA ${java_version} (Eclipse Temurin via Winget / direct MSI)
###############################################################################
Write-Log "Installing Eclipse Temurin Java ${java_version}..."

# Temurin MSI download URL pattern for Java 26 (update as new builds release).
# For production, pin to a specific build hash and verify the checksum.
$javaVersion  = "${java_version}"
$temurinBase  = "https://github.com/adoptium/temurin$${javaVersion}-binaries/releases/latest/download"
$javaMsiName  = "OpenJDK$${javaVersion}U-jdk_x64_windows_hotspot.msi"
$javaMsiPath  = "C:\statuspage\$javaMsiName"

try {
    Invoke-WebRequest -Uri "$temurinBase/$javaMsiName" -OutFile $javaMsiPath -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$javaMsiPath`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome /quiet /norestart" -Wait -NoNewWindow
    Write-Log "Java ${java_version} installed successfully."
} catch {
    Write-Log "ERROR installing Java: $_"
    throw
}

# Refresh PATH so java.exe is available in this session.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

###############################################################################
# 2. ACQUIRE MANAGED IDENTITY TOKEN FOR AZURE STORAGE
###############################################################################
Write-Log "Acquiring Managed Identity token for Azure Storage..."

$identityClientId = "${identity_client_id}"
$tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token" +
            "?api-version=2018-02-01" +
            "&resource=https://storage.azure.com/" +
            "&client_id=$identityClientId"

$tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = "true" } -Method GET
$storageToken  = $tokenResponse.access_token
Write-Log "Storage token acquired."

###############################################################################
# 3. DOWNLOAD ARTEFACTS FROM AZURE BLOB STORAGE
###############################################################################
$storageAccount = "${storage_account_name}"
$container      = "${container_name}"
$appDir         = "C:\statuspage\app"
New-Item -ItemType Directory -Force -Path $appDir | Out-Null

function Download-Blob {
    param([string]$BlobName, [string]$DestPath)
    $uri = "https://$storageAccount.blob.core.windows.net/$container/$BlobName"
    Write-Log "Downloading $BlobName from $uri..."
    Invoke-WebRequest -Uri $uri -OutFile $DestPath -UseBasicParsing -Headers @{
        Authorization = "Bearer $storageToken"
        "x-ms-version" = "2020-04-08"
    }
    Write-Log "Downloaded $BlobName → $DestPath"
}

Download-Blob -BlobName "statuspage.jar" -DestPath "$appDir\statuspage.jar"
Download-Blob -BlobName "winsw.exe"      -DestPath "$appDir\winsw.exe"

###############################################################################
# 4. CONFIGURE WinSW — Windows Service Wrapper
# WinSW reads statuspage-service.xml to know how to start the Java process.
###############################################################################
Write-Log "Writing WinSW service configuration..."

$appPort = "${app_port}"

$winswXml = @"
<service>
  <id>StatusPageService</id>
  <name>StatusPage API</name>
  <description>StatusPage Java 26 REST API — GET / and GET /health on port $appPort</description>
  <executable>java</executable>
  <arguments>-jar "$appDir\statuspage.jar"</arguments>
  <env name="PORT" value="$appPort" />
  <logmode>rotate</logmode>
  <logpath>C:\statuspage\logs</logpath>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="20 sec"/>
  <onfailure action="none"/>
</service>
"@

New-Item -ItemType Directory -Force -Path "C:\statuspage\logs" | Out-Null
$winswXml | Out-File -FilePath "$appDir\statuspage-service.xml" -Encoding UTF8

# Rename winsw.exe to match the XML filename (WinSW convention).
Copy-Item "$appDir\winsw.exe" "$appDir\statuspage-service.exe" -Force

Write-Log "Installing StatusPage Windows Service..."
& "$appDir\statuspage-service.exe" install
Write-Log "Starting StatusPage Windows Service..."
& "$appDir\statuspage-service.exe" start
Write-Log "StatusPage service started on port $appPort."

###############################################################################
# 5. CONFIGURE WINDOWS FIREWALL — allow inbound :8080
###############################################################################
Write-Log "Configuring Windows Firewall for port $appPort..."
New-NetFirewallRule -DisplayName "StatusPage HTTP $appPort" `
    -Direction Inbound -Protocol TCP -LocalPort $appPort `
    -Action Allow -Profile Any | Out-Null
Write-Log "Firewall rule created."

###############################################################################
# 6. CONFIGURE AZURE MONITOR AGENT (AMA) — Log Analytics workspace
# The AMA extension is installed by Terraform; this block writes the
# workspace configuration that the agent picks up.
###############################################################################
Write-Log "Configuring Azure Monitor Agent workspace..."

$lawWorkspaceId  = "${law_workspace_id}"
$lawWorkspaceKey = "${law_workspace_key}"

# Write MMA/OMS config for legacy compatibility (AMA uses DCR, but this
# ensures the workspace is registered for the agent).
$omsConfig = @{
    workspaceId  = $lawWorkspaceId
    workspaceKey = $lawWorkspaceKey
}
$omsConfig | ConvertTo-Json | Out-File "C:\statuspage\oms-config.json" -Encoding UTF8
Write-Log "Azure Monitor workspace configuration written."

###############################################################################
# 7. OPTIONAL — Nessus Agent (score 4/10 — uncomment to enable)
# Nessus is a local agent; there is no Azure managed equivalent.
# Requires a valid Nessus activation key and manager host.
###############################################################################
# Write-Log "Installing Nessus Agent (optional)..."
# $nessusInstaller = "C:\statuspage\NessusAgent.msi"
# Invoke-WebRequest -Uri "https://www.tenable.com/downloads/api/v1/public/pages/nessus-agents/downloads/XXXXX/download?i_agree_to_tenable_license_agreement=true" `
#     -OutFile $nessusInstaller -UseBasicParsing
# Start-Process msiexec.exe -ArgumentList "/i `"$nessusInstaller`" NESSUS_GROUPS=`"StatusPage`" NESSUS_SERVER=`"your-nessus-manager:8834`" NESSUS_KEY=`"YOUR_ACTIVATION_KEY`" /quiet /norestart" -Wait -NoNewWindow
# Write-Log "Nessus Agent installed."

###############################################################################
# 8. VERIFY SERVICE IS RUNNING
###############################################################################
Write-Log "Verifying StatusPage service health..."
Start-Sleep -Seconds 15

try {
    $response = Invoke-WebRequest -Uri "http://localhost:$appPort/health" -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -eq 200 -and $response.Content -eq "OK") {
        Write-Log "Health check PASSED — StatusPage is running on port $appPort."
    } else {
        Write-Log "WARNING: Health check returned unexpected response: $($response.StatusCode) / $($response.Content)"
    }
} catch {
    Write-Log "WARNING: Health check failed (service may still be starting): $_"
}

Write-Log "Bootstrap complete."