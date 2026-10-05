<#
.SYNOPSIS
    Downloads and silently installs UiPath Studio.

.DESCRIPTION
    Downloads the UiPath Studio MSI (a specific version or the latest) and
    installs it per-machine in either User mode (default) or Service mode.

    If UiPath Studio is already installed, the installed version is compared
    with the downloaded one:
      - Newer target version : upgrade in place
      - Same version         : nothing to do
      - Older target version : uninstall the existing version, then install

    Designed to be run as a one-liner:

        irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex

    Because "irm | iex" cannot pass arguments, options can also be supplied
    through environment variables:

        UIPATH_STUDIO_VERSION    e.g. 25.10.15 (omit for the latest version)
        UIPATH_STUDIO_MODE       User | Service
        UIPATH_ORCHESTRATOR_URL  e.g. https://cloud.uipath.com/org/tenant/orchestrator_

    Parameters take precedence over environment variables.

.PARAMETER Version
    UiPath Studio version to install (e.g. 25.10.15). If omitted, the latest
    version is installed.

.PARAMETER Mode
    Robot installation mode: User (default) or Service.

.PARAMETER OrchestratorUrl
    Optional Orchestrator URL, passed to the installer as ORCHESTRATOR_URL.

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -Mode Service
#>
param(
    [string]$Version,
    [string]$Mode,
    [string]$OrchestratorUrl
)

function Invoke-ComMember {
    param($Object, [string]$Name, [string]$Kind, [object[]]$Arguments = $null)
    # -NoEnumerate keeps COM collections (e.g. StringList) from being unrolled
    Write-Output -NoEnumerate $Object.GetType().InvokeMember($Name, $Kind, $null, $Object, $Arguments)
}

function Get-MsiProperties {
    # Reads selected properties from the Property table of an MSI file
    param([string]$Path, [string[]]$Names)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = Invoke-ComMember $installer 'OpenDatabase' 'InvokeMethod' @([string]$Path, 0)
    $result = @{}
    try {
        foreach ($name in $Names) {
            $view = Invoke-ComMember $database 'OpenView' 'InvokeMethod' @("SELECT Value FROM Property WHERE Property='$name'")
            [void](Invoke-ComMember $view 'Execute' 'InvokeMethod')
            $record = Invoke-ComMember $view 'Fetch' 'InvokeMethod'
            if ($record) {
                $result[$name] = Invoke-ComMember $record 'StringData' 'GetProperty' @(1)
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record)
            }
            [void](Invoke-ComMember $view 'Close' 'InvokeMethod')
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }
    }
    finally {
        # Release the database handle so the MSI file is not locked
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    $result
}

function Get-InstalledProducts {
    # Returns installed products that share the given MSI UpgradeCode
    param([string]$UpgradeCode)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $related = Invoke-ComMember $installer 'RelatedProducts' 'GetProperty' @($UpgradeCode)
    $count = Invoke-ComMember $related 'Count' 'GetProperty'
    for ($i = 0; $i -lt $count; $i++) {
        # Cast to [string]; COM calls reject PSObject-wrapped arguments
        $productCode = [string](Invoke-ComMember $related 'Item' 'GetProperty' @($i))
        [pscustomobject]@{
            ProductCode = $productCode
            Version     = Invoke-ComMember $installer 'ProductInfo' 'GetProperty' @($productCode, 'VersionString')
        }
    }
}

function ConvertTo-NormalizedVersion {
    # Pads a version string to 4 parts so that 25.10.15 equals 25.10.15.0
    param([string]$Value)
    $parts = @($Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    New-Object Version($parts[0], $parts[1], $parts[2], $parts[3])
}

function Invoke-Msiexec {
    param([string[]]$Arguments)
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments -Wait -PassThru
    $process.ExitCode
}

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
            throw "Invalid version '$Version'. Expected a format like 25.10.15."
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
    $uninstallLogPath = Join-Path $env:TEMP "UiPathStudio-uninstall-$timestamp.log"

    Write-Host 'UiPath Studio installer' -ForegroundColor Cyan
    Write-Host "  Version          : $versionLabel"
    Write-Host "  Mode             : $Mode"
    Write-Host "  Features         : $features"
    if ($OrchestratorUrl) { Write-Host "  Orchestrator URL : $OrchestratorUrl" }
    Write-Host ''

    try {
        Write-Host "Downloading $downloadUrl ..."
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing
        }
        catch {
            throw "Failed to download the installer from $downloadUrl. Check that version '$versionLabel' exists. $($_.Exception.Message)"
        }
        $sizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 1)
        Write-Host "Downloaded $sizeMB MB to $msiPath"

        # Check the downloaded package against any existing installation
        $msiProps = Get-MsiProperties -Path $msiPath -Names 'ProductVersion', 'UpgradeCode'
        if (-not $msiProps['ProductVersion'] -or -not $msiProps['UpgradeCode']) {
            throw 'Failed to read ProductVersion/UpgradeCode from the downloaded installer.'
        }
        $targetVersion = ConvertTo-NormalizedVersion $msiProps['ProductVersion']
        Write-Host "Package version: $targetVersion"

        $existing = @(Get-InstalledProducts -UpgradeCode $msiProps['UpgradeCode'])
        if ($existing.Count -eq 0) {
            Write-Host 'UiPath Studio is not installed. Performing a new installation.'
        }
        else {
            foreach ($product in $existing) {
                $installedVersion = ConvertTo-NormalizedVersion $product.Version
                Write-Host "Installed version: $installedVersion ($($product.ProductCode))"

                if ($targetVersion -gt $installedVersion) {
                    Write-Host "Upgrading UiPath Studio from $installedVersion to $targetVersion."
                }
                elseif ($targetVersion -eq $installedVersion) {
                    Write-Host "UiPath Studio $installedVersion is already installed. Nothing to do." -ForegroundColor Green
                    return
                }
                else {
                    Write-Host "The installed version $installedVersion is newer than $targetVersion. Uninstalling it first (this may take several minutes) ..."
                    $exitCode = Invoke-Msiexec @('/x', $product.ProductCode, '/qn', '/norestart', '/l*v', "`"$uninstallLogPath`"")
                    if ($exitCode -notin 0, 1641, 3010) {
                        throw "Failed to uninstall UiPath Studio $installedVersion (msiexec exit code $exitCode). Log: $uninstallLogPath"
                    }
                    Write-Host "Uninstalled UiPath Studio $installedVersion."
                }
            }
        }

        $msiArgs = @(
            '/i', "`"$msiPath`"",
            "ADDLOCAL=$features",
            '/qn', '/norestart',
            '/l*v', "`"$logPath`""
        )
        if ($OrchestratorUrl) { $msiArgs += "ORCHESTRATOR_URL=`"$OrchestratorUrl`"" }

        Write-Host 'Installing UiPath Studio (this may take several minutes) ...'
        $exitCode = Invoke-Msiexec $msiArgs
    }
    finally {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    }

    switch ($exitCode) {
        0 {
            Write-Host "UiPath Studio $targetVersion was installed successfully." -ForegroundColor Green
        }
        { $_ -in 1641, 3010 } {
            Write-Host "UiPath Studio $targetVersion was installed successfully. A restart is required to complete the installation." -ForegroundColor Yellow
        }
        1602 {
            throw "Installation was canceled by the user. Log: $logPath"
        }
        1618 {
            throw "Another installation is already in progress. Wait for it to finish and try again. Log: $logPath"
        }
        default {
            throw "Installation failed with msiexec exit code $exitCode. Log: $logPath"
        }
    }
    Write-Host "Installation log: $logPath"
}

Install-UiPathStudio -Version $Version -Mode $Mode -OrchestratorUrl $OrchestratorUrl
