<#
.SYNOPSIS
    Downloads and silently installs UiPath Studio.

.DESCRIPTION
    Downloads the UiPath Studio MSI (a specific version or the latest) and
    installs it per-machine in either User mode (default) or Service mode.

    Designed to be run as a one-liner:

        irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex

    Because "irm | iex" cannot pass arguments, options can also be supplied
    through environment variables:

        UIPATH_STUDIO_VERSION    e.g. 25.10.3 (omit for the latest version)
        UIPATH_STUDIO_MODE       User | Service
        UIPATH_ORCHESTRATOR_URL  e.g. https://cloud.uipath.com/org/tenant/orchestrator_

    Parameters take precedence over environment variables.

.PARAMETER Version
    UiPath Studio version to install (e.g. 25.10.3). If omitted, the latest
    version is installed.

.PARAMETER Mode
    Robot installation mode: User (default) or Service.

.PARAMETER OrchestratorUrl
    Optional Orchestrator URL, passed to the installer as ORCHESTRATOR_URL.

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.3 -Mode Service
#>
param(
    [string]$Version,
    [string]$Mode,
    [string]$OrchestratorUrl
)

function Install-UiPathStudio {
    param(
        [string]$Version,
        [string]$Mode,
        [string]$OrchestratorUrl
    )

    $ErrorActionPreference = 'Stop'
    # Invoke-WebRequest is very slow on Windows PowerShell 5.1 with the progress bar enabled
    $ProgressPreference = 'SilentlyContinue'

    # Fall back to environment variables when parameters are not given
    if (-not $Version) { $Version = $env:UIPATH_STUDIO_VERSION }
    if (-not $Mode) { $Mode = $env:UIPATH_STUDIO_MODE }
    if (-not $OrchestratorUrl) { $OrchestratorUrl = $env:UIPATH_ORCHESTRATOR_URL }

    if (-not $Mode) { $Mode = 'User' }
    switch -Regex ($Mode) {
        '^(?i)user$' { $Mode = 'User' }
        '^(?i)service$' { $Mode = 'Service' }
        default { throw "Invalid mode '$Mode'. Specify 'User' or 'Service'." }
    }

    if ($Version) {
        $Version = $Version.Trim()
        if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
            throw "Invalid version '$Version'. Expected a format like 25.10.3."
        }
        $downloadUrl = "https://download.uipath.com/versions/$Version/UiPathStudio.msi"
        $versionLabel = $Version
    }
    else {
        $downloadUrl = 'https://download.uipath.com/UiPathStudio.msi'
        $versionLabel = 'latest'
    }

    if ($OrchestratorUrl -and $OrchestratorUrl -notmatch '^https?://') {
        throw "Invalid Orchestrator URL '$OrchestratorUrl'. It must start with http:// or https://."
    }

    # A per-machine MSI installation requires administrator privileges
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required. Run PowerShell as Administrator and try again.'
    }

    # Ensure TLS 1.2 is available on older Windows PowerShell versions
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $features = 'Studio,Robot'
    if ($Mode -eq 'Service') { $features += ',RegisterService' }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $msiPath = Join-Path $env:TEMP "UiPathStudio-$versionLabel-$timestamp.msi"
    $logPath = Join-Path $env:TEMP "UiPathStudio-install-$timestamp.log"

    Write-Host 'UiPath Studio installer' -ForegroundColor Cyan
    Write-Host "  Version          : $versionLabel"
    Write-Host "  Mode             : $Mode"
    Write-Host "  Features         : $features"
    if ($OrchestratorUrl) { Write-Host "  Orchestrator URL : $OrchestratorUrl" }
    Write-Host ''

    Write-Host "Downloading $downloadUrl ..."
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing
    }
    catch {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        throw "Failed to download the installer from $downloadUrl. Check that version '$versionLabel' exists. $($_.Exception.Message)"
    }
    $sizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 1)
    Write-Host "Downloaded $sizeMB MB to $msiPath"

    $msiArgs = @(
        '/i', "`"$msiPath`"",
        "ADDLOCAL=$features",
        '/qn', '/norestart',
        '/l*v', "`"$logPath`""
    )
    if ($OrchestratorUrl) { $msiArgs += "ORCHESTRATOR_URL=`"$OrchestratorUrl`"" }

    Write-Host 'Installing UiPath Studio (this may take several minutes) ...'
    try {
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
        $exitCode = $process.ExitCode
    }
    finally {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    }

    switch ($exitCode) {
        0 {
            Write-Host 'UiPath Studio was installed successfully.' -ForegroundColor Green
        }
        { $_ -in 1641, 3010 } {
            Write-Host 'UiPath Studio was installed successfully. A restart is required to complete the installation.' -ForegroundColor Yellow
        }
        1602 {
            throw "Installation was canceled by the user. Log: $logPath"
        }
        1618 {
            throw "Another installation is already in progress. Wait for it to finish and try again. Log: $logPath"
        }
        1638 {
            throw "Another version of UiPath Studio is already installed. Uninstall it first to install this version. Log: $logPath"
        }
        default {
            throw "Installation failed with msiexec exit code $exitCode. Log: $logPath"
        }
    }
    Write-Host "Installation log: $logPath"
}

Install-UiPathStudio -Version $Version -Mode $Mode -OrchestratorUrl $OrchestratorUrl
