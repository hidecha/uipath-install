<#
.SYNOPSIS
    Downloads and silently installs UiPath Studio.

.DESCRIPTION
    Installs UiPath Studio per-machine in either User mode (default) or
    Service mode.

    Studio 2026.10 and later is distributed with the UiPath Platform installer.
    This script downloads the online MSI of the LTS release
    (e.g. UiPathPlatformLTS.26.10.msi), which installs the latest version of the
    release, and installs Studio, Robot and Runtimes through a
    platformConfig.json file. A classic installation is migrated, and an
    existing UiPath Platform installation is updated. If the installed Robot
    mode differs, the existing installation is uninstalled first.

    Earlier versions are installed with the classic UiPathStudio.msi. If UiPath
    Studio is already installed, the installed version is compared with the
    target one:
      - Newer target version : upgrade in place
      - Same version         : nothing to do, or switch the mode (User/Service)
                               if the installed mode differs
      - Older target version : uninstall the existing version, then install

    Designed to be run as a one-liner:

        irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex

    Because "irm | iex" cannot pass arguments, options can also be supplied
    through environment variables:

        UIPATH_STUDIO_VERSION    e.g. 26.10 / 25.10.15 (omit for the latest LTS version)
        UIPATH_SERVICE_MODE      1 = Service mode, 0 = User mode (default)
        UIPATH_ORCHESTRATOR_URL  e.g. https://cloud.uipath.com/org/tenant/orchestrator_

    Parameters take precedence over environment variables.

.PARAMETER Version
    UiPath Studio version to install.
      - Omitted        : the latest version of the latest LTS release (2026.10)
      - major.minor    : the latest version of that release, 26.10 or later (e.g. 26.10)
      - full version   : that exact version, earlier than 26.10 only (e.g. 25.10.15)

.PARAMETER ServiceMode
    Installs the Robot in Service mode. User mode is used when omitted.

.PARAMETER OrchestratorUrl
    Optional Orchestrator URL (SERVICE_URL for 2026.10 and later,
    ORCHESTRATOR_URL for earlier versions).

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 26.10 -ServiceMode
#>
param(
    [string]$Version,
    [switch]$ServiceMode,
    [string]$OrchestratorUrl
)

# The first Studio release distributed with the UiPath Platform installer
$PlatformMinVersion = [Version]'26.10.0.0'
# Release used when no version is specified
$LatestLtsRelease = '26.10'

$ClassicStudioUpgradeCode = '{63828A34-54AE-49FE-AEF7-9D81A499D6B8}'
$PlatformUpgradeCode = '{BF77B981-530C-4984-87AC-FBFDBBA4F8AB}'

function Invoke-ComMember {
    param($Object, [string]$Name, [string]$Kind, [object[]]$Arguments = $null)
    # The unary comma keeps COM collections (e.g. StringList) from being unrolled.
    # (Write-Output -NoEnumerate wraps the result in a List on PowerShell 7.)
    return , $Object.GetType().InvokeMember($Name, $Kind, $null, $Object, $Arguments)
}

function Remove-ComObject {
    param($Object)
    # PowerShell 7 wraps returned COM objects in a PSObject; unwrap before releasing
    if ($Object -is [psobject]) { $Object = $Object.psobject.BaseObject }
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object)
    }
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
                Remove-ComObject $record
            }
            [void](Invoke-ComMember $view 'Close' 'InvokeMethod')
            Remove-ComObject $view
        }
    }
    finally {
        # Release the database handle so the MSI file is not locked
        Remove-ComObject $database
        Remove-ComObject $installer
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    $result
}

function Get-RelatedProductCodes {
    # Returns the product codes of installed products that share the given MSI UpgradeCode
    param([string]$UpgradeCode)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $related = Invoke-ComMember $installer 'RelatedProducts' 'GetProperty' @($UpgradeCode)
    $count = Invoke-ComMember $related 'Count' 'GetProperty'
    for ($i = 0; $i -lt $count; $i++) {
        # Cast to [string]; COM calls reject PSObject-wrapped arguments
        [string](Invoke-ComMember $related 'Item' 'GetProperty' @($i))
    }
}

function Get-ClassicStudio {
    # Returns classic (UiPathStudio.msi) installations
    $installer = New-Object -ComObject WindowsInstaller.Installer
    foreach ($productCode in @(Get-RelatedProductCodes $ClassicStudioUpgradeCode)) {
        # Service mode is the RegisterService feature (3 = local, 4 = source, 5 = default)
        $serviceState = Invoke-ComMember $installer 'FeatureState' 'GetProperty' @($productCode, 'RegisterService')
        [pscustomobject]@{
            Kind        = 'Classic'
            ProductCode = $productCode
            Version     = ConvertTo-NormalizedVersion (Invoke-ComMember $installer 'ProductInfo' 'GetProperty' @($productCode, 'VersionString'))
            Mode        = if ($serviceState -in 3, 4, 5) { 'Service' } else { 'User' }
        }
    }
}

function Get-PlatformStudio {
    # Returns UiPath Platform installations. The MSI version is the updater version,
    # so the Studio version is read from %ProgramFiles%\UiPathPlatform\Studio\<version>.
    foreach ($productCode in @(Get-RelatedProductCodes $PlatformUpgradeCode)) {
        $studioVersion = $null
        $studioRoot = Join-Path $env:ProgramFiles 'UiPathPlatform\Studio'
        if (Test-Path $studioRoot) {
            # Folder names may carry a suffix, e.g. 26.0.204-cloud.25540
            $studioVersion = Get-ChildItem -Path $studioRoot -Directory |
                Where-Object { $_.Name -match '^(\d+(\.\d+){1,3})(-|$)' } |
                ForEach-Object { ConvertTo-NormalizedVersion ($_.Name -replace '-.*$', '') } |
                Sort-Object -Descending | Select-Object -First 1
        }
        [pscustomobject]@{
            Kind        = 'Platform'
            ProductCode = $productCode
            Version     = $studioVersion
            # The Robot is registered as the UiRobotSvc Windows service in Service mode
            Mode        = if (Get-Service -Name 'UiRobotSvc' -ErrorAction SilentlyContinue) { 'Service' } else { 'User' }
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

function Invoke-Installer {
    param([string]$FilePath, [string[]]$Arguments)
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
    $process.ExitCode
}

function Uninstall-Product {
    param($Product, [string]$LogPath)
    $label = if ($Product.Version) { "UiPath Studio $($Product.Version)" } else { 'UiPath Studio' }
    Write-Host "Uninstalling $label ($($Product.Kind), $($Product.ProductCode)). This may take several minutes ..."
    $exitCode = Invoke-Installer 'msiexec.exe' @('/x', $Product.ProductCode, '/qn', '/norestart', '/l*v', "`"$LogPath`"")
    if ($exitCode -notin 0, 1641, 3010) {
        throw "Failed to uninstall $label (msiexec exit code $exitCode). Log: $LogPath"
    }
    Write-Host "Uninstalled $label."
}

function Save-Installer {
    param([string]$Url, [string]$Path, [string]$VersionLabel)
    Write-Host "Downloading $Url ..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    }
    catch {
        throw "Failed to download the installer from $Url. Check that version '$VersionLabel' exists. $($_.Exception.Message)"
    }
    $sizeMB = [math]::Round((Get-Item $Path).Length / 1MB, 1)
    Write-Host "Downloaded $sizeMB MB to $Path"
}

function Install-ClassicStudio {
    # Studio 2025.10 and earlier: classic UiPathStudio.msi
    param([string]$Version, [string]$Mode, [string]$OrchestratorUrl, [string]$Timestamp)

    if ($Version) {
        $downloadUrl = "https://download.uipath.com/versions/$Version/UiPathStudio.msi"
    }
    else {
        $downloadUrl = 'https://download.uipath.com/UiPathStudio.msi'
    }
    $features = 'Studio,Robot'
    if ($Mode -eq 'Service') { $features += ',RegisterService' }

    $msiPath = Join-Path $env:TEMP "UiPathStudio-$Version-$Timestamp.msi"
    $logPath = Join-Path $env:TEMP "UiPathStudio-install-$Timestamp.log"
    $uninstallLogPath = Join-Path $env:TEMP "UiPathStudio-uninstall-$Timestamp.log"

    Write-Host "  Installer        : Classic MSI (features: $features)"
    Write-Host ''

    try {
        Save-Installer -Url $downloadUrl -Path $msiPath -VersionLabel $Version

        # Check the downloaded package against any existing installation
        $msiProps = Get-MsiProperties -Path $msiPath -Names 'ProductVersion'
        if (-not $msiProps['ProductVersion']) {
            throw 'Failed to read ProductVersion from the downloaded installer.'
        }
        $targetVersion = ConvertTo-NormalizedVersion $msiProps['ProductVersion']
        Write-Host "Package version: $targetVersion"

        # Going back to the classic installer requires removing the UiPath Platform first
        foreach ($product in @(Get-PlatformStudio)) {
            Write-Host "UiPath Platform is installed (Studio $($product.Version)). It must be removed to install a classic version."
            Uninstall-Product $product $uninstallLogPath
        }

        $existing = @(Get-ClassicStudio)
        $maintenanceProductCode = $null
        if ($existing.Count -eq 0) {
            Write-Host 'UiPath Studio is not installed. Performing a new installation.'
        }
        foreach ($product in $existing) {
            Write-Host "Installed version: $($product.Version), $($product.Mode) mode ($($product.ProductCode))"
            if ($targetVersion -gt $product.Version) {
                Write-Host "Upgrading UiPath Studio from $($product.Version) to $targetVersion."
            }
            elseif ($targetVersion -eq $product.Version) {
                if ($product.Mode -eq $Mode) {
                    Write-Host "UiPath Studio $($product.Version) is already installed in $Mode mode. Nothing to do." -ForegroundColor Green
                    return
                }
                Write-Host "Changing the mode of UiPath Studio $($product.Version) from $($product.Mode) to $Mode."
                # Modify the installed product (maintenance mode) instead of reinstalling it
                $maintenanceProductCode = $product.ProductCode
            }
            else {
                Write-Host "The installed version $($product.Version) is newer than $targetVersion."
                Uninstall-Product $product $uninstallLogPath
            }
        }

        $msiArgs = @(
            '/i', $(if ($maintenanceProductCode) { $maintenanceProductCode } else { "`"$msiPath`"" }),
            "ADDLOCAL=$features",
            '/qn', '/norestart',
            '/l*v', "`"$logPath`""
        )
        # ADDLOCAL only adds features; Service mode must be removed explicitly
        # (an upgrade would otherwise carry the RegisterService feature over)
        if ($Mode -eq 'User' -and @($existing | Where-Object { $_.Mode -eq 'Service' }).Count -gt 0) {
            $msiArgs += 'REMOVE=RegisterService'
        }
        if ($OrchestratorUrl) { $msiArgs += "ORCHESTRATOR_URL=`"$OrchestratorUrl`"" }

        Write-Host 'Installing UiPath Studio (this may take several minutes) ...'
        $exitCode = Invoke-Installer 'msiexec.exe' $msiArgs
    }
    finally {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    }

    Complete-Installation -ExitCode $exitCode -VersionLabel $targetVersion -LogPath $logPath
}

function Install-PlatformStudio {
    # Studio 2026.10 and later: UiPath Platform online MSI (e.g. UiPathPlatformLTS.26.10.msi).
    # The MSI downloads the products from its update channel during the installation,
    # so it always installs the latest version of the release.
    param([string]$Version, [string]$Mode, [string]$OrchestratorUrl, [string]$Timestamp)

    $release = [Version]$Version
    $releaseName = "$($release.Major).$($release.Minor)"
    $msiName = "UiPathPlatformLTS.$releaseName.msi"
    $downloadUrl = "https://download.uipath.com/connected-installer/latest/lts-$($release.Major)-$($release.Minor)/$msiName"

    $msiPath = Join-Path $env:TEMP "UiPathPlatformLTS-$releaseName-$Timestamp.msi"
    $configPath = Join-Path $env:TEMP "UiPathPlatform-config-$Timestamp.json"
    $logPath = Join-Path $env:TEMP "UiPathPlatform-install-$Timestamp.log"
    $uninstallLogPath = Join-Path $env:TEMP "UiPathPlatform-uninstall-$Timestamp.log"

    Write-Host "  Installer        : $msiName (Studio, Robot, Runtimes)"
    Write-Host ''

    $toUninstall = @()
    $existingCount = 0
    $migrating = $false
    foreach ($product in @(Get-ClassicStudio)) {
        $existingCount++
        Write-Host "Installed version: $($product.Version), $($product.Mode) mode (classic MSI, $($product.ProductCode))"
        if ($product.Mode -eq $Mode) {
            # The installer migrates the classic installation and keeps its settings
            Write-Host "Migrating UiPath Studio $($product.Version) to the UiPath Platform installer."
            $migrating = $true
        }
        else {
            # A migration keeps the classic Robot mode, so reinstall to change it
            Write-Host "Changing the mode from $($product.Mode) to $Mode requires reinstalling."
            $toUninstall += $product
        }
    }
    foreach ($product in @(Get-PlatformStudio)) {
        $existingCount++
        $installedLabel = if ($product.Version) { $product.Version } else { 'unknown version' }
        Write-Host "Installed version: $installedLabel, $($product.Mode) mode (UiPath Platform, $($product.ProductCode))"
        if ($product.Mode -ne $Mode) {
            Write-Host "Changing the mode from $($product.Mode) to $Mode requires reinstalling."
            $toUninstall += $product
        }
        else {
            Write-Host "Updating the existing UiPath Platform installation to the latest $releaseName version."
        }
    }
    if ($existingCount -eq 0) {
        Write-Host 'UiPath Studio is not installed. Performing a new installation.'
    }

    $robotParameters = [ordered]@{
        REGISTER_ROBOT_SERVICE = $(if ($Mode -eq 'Service') { 'True' } else { 'False' })
    }
    if ($OrchestratorUrl) { $robotParameters['SERVICE_URL'] = $OrchestratorUrl }
    $config = [ordered]@{
        Packages = @(
            [ordered]@{ PackageName = 'Studio'; InstallRequested = $true; Parameters = @{} }
            [ordered]@{ PackageName = 'Robot'; InstallRequested = $true; Parameters = $robotParameters }
            [ordered]@{ PackageName = 'Runtimes'; InstallRequested = $true; Parameters = @{} }
        )
    }

    try {
        Save-Installer -Url $downloadUrl -Path $msiPath -VersionLabel $releaseName

        foreach ($product in $toUninstall) {
            Uninstall-Product $product $uninstallLogPath
        }
        if ($migrating) {
            Write-Host 'Note: during a migration the settings (including the Orchestrator URL) are taken from the classic installation.' -ForegroundColor Yellow
        }

        # Write the configuration without a BOM (Windows PowerShell's UTF8 encoding adds one)
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

        $msiArgs = @(
            '/i', "`"$msiPath`"",
            'MSIINSTALLPERUSER=0',
            "PLATFORM_CONFIGURATION_FILE=`"$configPath`"",
            '/qn', '/norestart',
            '/l*v', "`"$logPath`""
        )
        Write-Host 'Installing UiPath Studio (the products are downloaded during the installation; this may take several minutes) ...'
        $exitCode = Invoke-Installer 'msiexec.exe' $msiArgs
    }
    finally {
        Remove-Item -Path $msiPath, $configPath -Force -ErrorAction SilentlyContinue
    }

    $installedVersion = (@(Get-PlatformStudio) | Select-Object -First 1).Version
    $versionLabel = if ($installedVersion) { $installedVersion } else { $releaseName }
    Complete-Installation -ExitCode $exitCode -VersionLabel $versionLabel -LogPath $logPath
}

function Complete-Installation {
    param([int]$ExitCode, [string]$VersionLabel, [string]$LogPath)

    switch ($ExitCode) {
        0 {
            Write-Host "UiPath Studio $VersionLabel was installed successfully." -ForegroundColor Green
        }
        { $_ -in 1641, 3010 } {
            Write-Host "UiPath Studio $VersionLabel was installed successfully. A restart is required to complete the installation." -ForegroundColor Yellow
        }
        1602 { throw "Installation was canceled. Log: $LogPath" }
        1618 { throw "Another installation is already in progress. Wait for it to finish and try again. Log: $LogPath" }
        4004 { throw "Insufficient disk space. Free up disk space and try again. Log: $LogPath" }
        4026 { throw "A newer version of UiPath Studio is already installed than the one published on the channel. Log: $LogPath" }
        default { throw "Installation failed with exit code $ExitCode. Log: $LogPath" }
    }
    Write-Host "Installation log: $LogPath"
}

function Install-UiPathStudio {
    param(
        [string]$Version,
        [switch]$ServiceMode,
        [string]$OrchestratorUrl
    )

    $ErrorActionPreference = 'Stop'
    # Invoke-WebRequest is very slow on Windows PowerShell 5.1 with the progress bar enabled
    $ProgressPreference = 'SilentlyContinue'

    # Fall back to environment variables when parameters are not given
    if (-not $Version) { $Version = $env:UIPATH_STUDIO_VERSION }
    if (-not $OrchestratorUrl) { $OrchestratorUrl = $env:UIPATH_ORCHESTRATOR_URL }
    if (-not $ServiceMode -and $env:UIPATH_SERVICE_MODE) {
        switch ($env:UIPATH_SERVICE_MODE.Trim()) {
            '1' { $ServiceMode = $true }
            '0' { }
            default { throw "Invalid UIPATH_SERVICE_MODE '$env:UIPATH_SERVICE_MODE'. Specify 1 (Service mode) or 0 (User mode)." }
        }
    }
    $Mode = if ($ServiceMode) { 'Service' } else { 'User' }

    if (-not $Version) { $Version = $LatestLtsRelease }
    $Version = $Version.Trim()
    if ($Version -notmatch '^\d+\.\d+(\.\d+){0,2}$') {
        throw "Invalid version '$Version'. Expected a format like 26.10 or 25.10.15."
    }
    $usePlatform = (ConvertTo-NormalizedVersion $Version) -ge $PlatformMinVersion
    if (-not $usePlatform -and $Version.Split('.').Count -eq 2) {
        throw "Invalid version '$Version'. Versions earlier than 26.10 must be fully specified (e.g. 25.10.15)."
    }
    if ($usePlatform -and $Version.Split('.').Count -ne 2) {
        # The online MSI always installs the latest version of its release
        throw "Invalid version '$Version'. For 26.10 and later, specify the release only (e.g. 26.10); the latest version of the release is installed."
    }

    if ($OrchestratorUrl -and $OrchestratorUrl -notmatch '^https?://') {
        throw "Invalid Orchestrator URL '$OrchestratorUrl'. It must start with http:// or https://."
    }

    # A per-machine installation requires administrator privileges
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required. Run PowerShell as Administrator and try again.'
    }

    # Ensure TLS 1.2 is available on older Windows PowerShell versions
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Host 'UiPath Studio installer' -ForegroundColor Cyan
    Write-Host "  Version          : $(if ($Version.Split('.').Count -eq 2) { "$Version (latest)" } else { $Version })"
    Write-Host "  Mode             : $Mode"
    if ($OrchestratorUrl) { Write-Host "  Orchestrator URL : $OrchestratorUrl" }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $installArgs = @{ Version = $Version; Mode = $Mode; OrchestratorUrl = $OrchestratorUrl; Timestamp = $timestamp }
    if ($usePlatform) { Install-PlatformStudio @installArgs } else { Install-ClassicStudio @installArgs }
}

Install-UiPathStudio -Version $Version -ServiceMode:$ServiceMode -OrchestratorUrl $OrchestratorUrl
