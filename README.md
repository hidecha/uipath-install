# uipath-install

English | [日本語](README.ja.md)

A PowerShell script that downloads and silently installs UiPath Studio with a single command.

- Install the latest version of a release (e.g. `26.10`) or a specific classic version (e.g. `25.10.15`)
- Studio 2026.10 and later is installed with the **UiPath Platform online MSI** (`UiPathPlatformLTS.26.10.msi`); earlier versions with the classic MSI
- Choose the Robot mode: **User mode** (default) or **Service mode**
- Optionally set the Orchestrator URL
- Handles an existing installation: upgrades (or migrates) an older version, switches the mode, or uninstalls a newer version before installing

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x
- PowerShell running **as Administrator** (the installation is per-machine)
- Internet access to `raw.githubusercontent.com` and `download.uipath.com` (for 2026.10 and later, the products are downloaded during the installation as well)
- 3.4 GB of free disk space for 2026.10 and later (2.4 GB for a migration)

## Quick start

Open PowerShell as Administrator and run:

```powershell
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

This installs the **latest 2026.10 LTS** version of UiPath Studio in **User mode**.

## Options

| Parameter          | Environment variable      | Description                                                                                  | Default  |
| ------------------ | ------------------------- | -------------------------------------------------------------------------------------------- | -------- |
| `-Version`         | `UIPATH_STUDIO_VERSION`   | Studio version to install (`26.10` = latest of that release, `25.10.15`, ...)                | `26.10`  |
| `-ServiceMode`     | `UIPATH_SERVICE_MODE`     | Service mode. With the environment variable, `1` = Service mode, `0` = User mode             | User mode (`0`) |
| `-OrchestratorUrl` | `UIPATH_ORCHESTRATOR_URL` | Orchestrator URL (`SERVICE_URL` for 2026.10 and later, `ORCHESTRATOR_URL` for earlier ones)  | (none)   |

Parameters take precedence over environment variables. For 26.10 and later, specify the release only (e.g. `26.10`); the online MSI always installs the latest version of the release. Versions earlier than 26.10 must be fully specified (e.g. `25.10.15`).

> Currently, the UiPath Platform installer is supported for the 2026.10 LTS release (`UiPathPlatformLTS.26.10.msi`).

> `UIPATH_STUDIO_MODE` and `-Mode` have been replaced by `UIPATH_SERVICE_MODE` and `-ServiceMode`.

Since `irm ... | iex` cannot pass arguments, use one of the following methods.

### Method 1: Environment variables

```powershell
$env:UIPATH_STUDIO_VERSION = '26.10'
$env:UIPATH_SERVICE_MODE = '1'
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

### Method 2: Pass parameters to a script block

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 26.10 -ServiceMode
```

With an Orchestrator URL:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -OrchestratorUrl https://cloud.uipath.com/myorg/mytenant/orchestrator_
```

## What the script does

### Studio 2026.10 and later (UiPath Platform online MSI)

1. Checks existing installations (classic MSI and UiPath Platform).

   | Existing installation                     | Action                                                                    |
   | ----------------------------------------- | ------------------------------------------------------------------------- |
   | None                                      | New installation                                                          |
   | Classic MSI, same mode                    | Migrated by the installer (settings are taken from the classic installation) |
   | Classic MSI, different mode               | Uninstalled, then new installation                                        |
   | UiPath Platform, same mode                | Updated to the latest version of the release                              |
   | UiPath Platform, different mode           | Uninstalled, then new installation                                        |

   The installed Studio version is read from `%ProgramFiles%\UiPathPlatform\Studio\<version>`, and Service mode is
   detected by the `UiRobotSvc` Windows service.

2. Downloads the online MSI to `%TEMP%`
   (e.g. `https://download.uipath.com/connected-installer/latest/lts-26-10/UiPathPlatformLTS.26.10.msi`).
3. Writes a `platformConfig.json` that installs `Studio`, `Robot` and `Runtimes`
   (`REGISTER_ROBOT_SERVICE` = `True` in Service mode, `SERVICE_URL` = Orchestrator URL) and runs:

   ```
   msiexec /i UiPathPlatformLTS.26.10.msi MSIINSTALLPERUSER=0 PLATFORM_CONFIGURATION_FILE=<config> /qn /norestart /l*v <log>
   ```

4. Deletes the MSI and the configuration file and prints the log path (`%TEMP%\UiPathPlatform-install-<timestamp>.log`).

### Studio 2025.10 and earlier (classic MSI)

1. Downloads `https://download.uipath.com/versions/{Version}/UiPathStudio.msi` to `%TEMP%`.
2. If UiPath Platform is installed, uninstalls it first (required to go back to the classic installer).
3. Reads the package version from the MSI and checks for an existing classic installation (by the MSI UpgradeCode).

   | Existing installation        | Action                                                        |
   | ---------------------------- | ------------------------------------------------------------- |
   | None                         | New installation                                              |
   | Older than the package       | Upgraded in place                                             |
   | Same version as the package  | Nothing to do if the mode matches; otherwise switches the mode (User ⇔ Service) |
   | Newer than the package       | Uninstalled, then new installation                            |

4. Runs `msiexec` silently with `ADDLOCAL=Studio,Robot` (plus `RegisterService` in Service mode).
   `REMOVE=RegisterService` is added when switching from Service mode to User mode.

   ```
   msiexec /i UiPathStudio.msi ADDLOCAL=Studio,Robot[,RegisterService] [ORCHESTRATOR_URL=...] /qn /norestart /l*v <log>
   ```

Uninstall logs are saved to `%TEMP%\UiPathStudio-uninstall-<timestamp>.log` / `%TEMP%\UiPathPlatform-uninstall-<timestamp>.log`.
The system is never restarted automatically; a message is shown if a restart is required.

## Troubleshooting

| Message                                              | Cause / Solution                                                                                     |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `Administrator privileges are required.`             | Run PowerShell as Administrator.                                                                     |
| `Failed to download the installer ...`               | The version does not exist or the network is blocked. Check the version number.                      |
| `Failed to uninstall UiPath Studio ...`              | Uninstalling the existing installation failed. Check the uninstall log shown in the message.         |
| `Insufficient disk space.`                           | Free up disk space (3.4 GB for a new installation, 2.4 GB for a migration).                          |
| `A newer version of UiPath Studio is already installed ...` | The installed version is newer than the one on the channel. Uninstall it first.               |
| `Installation failed with exit code N`               | Check the installation logs shown in the message.                                                    |

If `irm` fails because of TLS on an older Windows PowerShell, run this first:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

## References

- [Migrate from the classic MSI installers](https://docs.uipath.com/uipath-platform-installer/standalone/latest/user-guide/migrate-from-classic-msi)
- [Install from the command line (UiPath Platform installer)](https://docs.uipath.com/uipath-platform-installer/standalone/latest/user-guide/install-from-the-command-line)
- [Studio command-line parameters (classic MSI)](https://docs.uipath.com/studio/standalone/2025.10/user-guide/command-line-parameters)
