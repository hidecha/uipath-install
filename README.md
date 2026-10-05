# uipath-install

English | [日本語](README.ja.md)

A PowerShell script that downloads and silently installs UiPath Studio with a single command.

- Install a specific version (e.g. `25.10.15`) or the latest version
- Choose the Robot mode: **User mode** (default) or **Service mode**
- Optionally set the Orchestrator URL
- Handles an existing installation: upgrades an older version, or uninstalls a newer version before installing

## Requirements

- Windows with PowerShell 5.1 or later
- PowerShell running **as Administrator** (the installation is per-machine)
- Internet access to `raw.githubusercontent.com` and `download.uipath.com`

## Quick start

Open PowerShell as Administrator and run:

```powershell
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

This installs the **latest** version of UiPath Studio in **User mode**.

## Options

| Parameter          | Environment variable      | Description                                                           | Default |
| ------------------ | ------------------------- | --------------------------------------------------------------------- | ------- |
| `-Version`         | `UIPATH_STUDIO_VERSION`   | Studio version to install (e.g. `25.10.15`)                            | latest  |
| `-Mode`            | `UIPATH_STUDIO_MODE`      | `User` or `Service`                                                   | `User`  |
| `-OrchestratorUrl` | `UIPATH_ORCHESTRATOR_URL` | Orchestrator URL (passed to the installer as `ORCHESTRATOR_URL`)      | (none)  |

Parameters take precedence over environment variables.

Since `irm ... | iex` cannot pass arguments, use one of the following methods.

### Method 1: Environment variables

```powershell
$env:UIPATH_STUDIO_VERSION = '25.10.15'
$env:UIPATH_STUDIO_MODE = 'Service'
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

### Method 2: Script block with parameters

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -Mode Service
```

With an Orchestrator URL:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -OrchestratorUrl https://cloud.uipath.com/myorg/mytenant/orchestrator_
```

## What the script does

1. Downloads the MSI to `%TEMP%`
   - Specific version: `https://download.uipath.com/versions/{Version}/UiPathStudio.msi`
   - Latest version: `https://download.uipath.com/UiPathStudio.msi`
2. Reads the package version from the MSI and checks for an existing UiPath Studio installation
   (detected by the MSI UpgradeCode):

   | Existing installation           | Action                                                   |
   | ------------------------------- | -------------------------------------------------------- |
   | None                            | New installation                                         |
   | Older than the package          | Upgrade in place                                         |
   | Same version as the package     | Nothing to do (the script exits without changes)         |
   | Newer than the package          | Uninstall the existing version, then install the package |

3. Runs `msiexec` silently with the following features:

   | Mode    | `ADDLOCAL`                        |
   | ------- | --------------------------------- |
   | User    | `Studio,Robot`                    |
   | Service | `Studio,Robot,RegisterService`    |

   Equivalent command:

   ```
   msiexec /i UiPathStudio.msi ADDLOCAL=Studio,Robot[,RegisterService] [ORCHESTRATOR_URL=...] /qn /norestart /l*v <log>
   ```

4. Deletes the downloaded MSI and prints the path of the installation log
   (`%TEMP%\UiPathStudio-install-<timestamp>.log`). When an existing version is uninstalled,
   its log is saved to `%TEMP%\UiPathStudio-uninstall-<timestamp>.log`.

The system is never restarted automatically. If a restart is required, the script displays a message.

## Troubleshooting

| Message                                       | Cause / Solution                                                                       |
| --------------------------------------------- | -------------------------------------------------------------------------------------- |
| `Administrator privileges are required.`      | Run PowerShell as Administrator.                                                       |
| `Failed to download the installer ...`        | The version does not exist or the network is blocked. Check the version number.       |
| `Failed to uninstall UiPath Studio ...`       | Uninstalling the newer existing version failed. See the uninstall log in the message. |
| `Installation failed with msiexec exit code N` | See the installation log shown in the message.                                        |

If `irm` fails on older Windows PowerShell because of TLS, run this first:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

## References

- [Studio command-line parameters](https://docs.uipath.com/studio/standalone/2025.10/user-guide/command-line-parameters)
