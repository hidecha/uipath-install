# uipath-install

[English](README.md) | 日本語

UiPath Studio を 1 行のコマンドでダウンロードし、サイレントインストールする PowerShell スクリプトです。

- リリースの最新バージョン (例: `26.10`) または従来の特定バージョン (例: `25.10.15`) をインストール
- Studio 2026.10 以降は **UiPath Platform オンライン MSI** (`UiPathPlatformLTS.26.10.msi`)、それより前のバージョンは従来の MSI でインストール
- Robot のモードを **ユーザーモード** (既定) または **サービスモード** から選択
- Orchestrator URL を任意で設定
- 既存のインストールに対応: 古いバージョンはアップグレード (または移行)、モードの切り替え、新しいバージョンはアンインストールしてからインストール

## 前提条件

- Windows PowerShell 5.1 または PowerShell 7.x
- **管理者として実行** した PowerShell (マシン単位でインストールするため)
- `raw.githubusercontent.com` と `download.uipath.com` へのインターネット接続 (2026.10 以降は、インストール中にも製品がダウンロードされます)
- 2026.10 以降では 3.4 GB の空き容量 (移行の場合は 2.4 GB)

## クイックスタート

PowerShell を管理者として開き、次のコマンドを実行します。

```powershell
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

UiPath Studio の **2026.10 LTS の最新バージョン** が **ユーザーモード** でインストールされます。

## オプション

| パラメーター       | 環境変数                  | 説明                                                                                         | 既定値   |
| ------------------ | ------------------------- | -------------------------------------------------------------------------------------------- | -------- |
| `-Version`         | `UIPATH_STUDIO_VERSION`   | インストールする Studio のバージョン (`26.10` = そのリリースの最新版、`25.10.15` など) | `26.10`  |
| `-ServiceMode`     | `UIPATH_SERVICE_MODE`     | サービスモード。環境変数では `1` = サービスモード、`0` = ユーザーモード                      | ユーザーモード (`0`) |
| `-OrchestratorUrl` | `UIPATH_ORCHESTRATOR_URL` | Orchestrator URL (2026.10 以降は `SERVICE_URL`、それより前は `ORCHESTRATOR_URL` として渡されます) | (なし)   |

パラメーターは環境変数より優先されます。26.10 以降はリリースのみ (例: `26.10`) を指定してください。オンライン MSI は常にそのリリースの最新バージョンをインストールします。26.10 より前のバージョンは完全なバージョン番号 (例: `25.10.15`) で指定してください。

> 現在、UiPath Platform インストーラーは 2026.10 LTS リリース (`UiPathPlatformLTS.26.10.msi`) に対応しています。

> `UIPATH_STUDIO_MODE` と `-Mode` は、`UIPATH_SERVICE_MODE` と `-ServiceMode` に置き換えられました。

`irm ... | iex` では引数を渡せないため、次のいずれかの方法を使用してください。

### 方法 1: 環境変数

```powershell
$env:UIPATH_STUDIO_VERSION = '26.10'
$env:UIPATH_SERVICE_MODE = '1'
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

### 方法 2: スクリプトブロックにパラメーターを渡す

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 26.10 -ServiceMode
```

Orchestrator URL を指定する場合:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -OrchestratorUrl https://cloud.uipath.com/myorg/mytenant/orchestrator_
```

## スクリプトの処理内容

### Studio 2026.10 以降 (UiPath Platform オンライン MSI)

1. 既存のインストール (従来の MSI と UiPath Platform) を確認します。

   | 既存のインストール                         | 処理                                                         |
   | ------------------------------------------ | ------------------------------------------------------------ |
   | なし                                       | 新規インストール                                             |
   | 従来の MSI、モードが同じ                   | インストーラーが移行します (設定は従来のインストールから引き継がれます) |
   | 従来の MSI、モードが異なる                 | アンインストールしてから新規インストール                     |
   | UiPath Platform、モードが同じ              | リリースの最新バージョンに更新                               |
   | UiPath Platform、モードが異なる            | アンインストールしてから新規インストール                     |

   インストール済みの Studio のバージョンは `%ProgramFiles%\UiPathPlatform\Studio\<version>` から、
   サービスモードは Windows サービス `UiRobotSvc` の有無から判定します。

2. オンライン MSI を `%TEMP%` にダウンロードします
   (例: `https://download.uipath.com/connected-installer/latest/lts-26-10/UiPathPlatformLTS.26.10.msi`)。
3. `Studio`、`Robot`、`Runtimes` をインストールする `platformConfig.json` を作成し
   (サービスモードでは `REGISTER_ROBOT_SERVICE` = `True`、`SERVICE_URL` = Orchestrator URL)、次のコマンドを実行します。

   ```
   msiexec /i UiPathPlatformLTS.26.10.msi MSIINSTALLPERUSER=0 PLATFORM_CONFIGURATION_FILE=<config> /qn /norestart /l*v <log>
   ```

4. MSI と構成ファイルを削除し、ログのパス (`%TEMP%\UiPathPlatform-install-<timestamp>.log`) を表示します。

### Studio 2025.10 以前 (従来の MSI)

1. `https://download.uipath.com/versions/{Version}/UiPathStudio.msi` を `%TEMP%` にダウンロードします。
2. UiPath Platform がインストールされている場合は、先にアンインストールします (従来のインストーラーに戻すために必要です)。
3. MSI からパッケージのバージョンを読み取り、既存の従来のインストールを確認します (MSI の UpgradeCode で検出します)。

   | 既存のインストール         | 処理                                                     |
   | -------------------------- | -------------------------------------------------------- |
   | なし                       | 新規インストール                                         |
   | パッケージより古い         | 上書きでアップグレード                                   |
   | パッケージと同じバージョン | モードが同じなら何もしません。異なる場合はモードを切り替えます (ユーザー ⇔ サービス) |
   | パッケージより新しい       | 既存バージョンをアンインストールしてから新規インストール |

4. `ADDLOCAL=Studio,Robot` (サービスモードでは `RegisterService` を追加) を指定して `msiexec` をサイレント実行します。
   サービスモードからユーザーモードに切り替える場合は `REMOVE=RegisterService` を追加します。

   ```
   msiexec /i UiPathStudio.msi ADDLOCAL=Studio,Robot[,RegisterService] [ORCHESTRATOR_URL=...] /qn /norestart /l*v <log>
   ```

アンインストールのログは `%TEMP%\UiPathStudio-uninstall-<timestamp>.log` / `%TEMP%\UiPathPlatform-uninstall-<timestamp>.log` に保存されます。
システムが自動的に再起動されることはありません。再起動が必要な場合はメッセージが表示されます。

## トラブルシューティング

| メッセージ                                               | 原因 / 対処方法                                                                    |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Administrator privileges are required.`                 | PowerShell を管理者として実行してください。                                        |
| `Failed to download the installer ...`                   | 指定したバージョンが存在しないか、ネットワークがブロックされています。バージョン番号を確認してください。 |
| `Failed to uninstall UiPath Studio ...`                  | 既存のインストールのアンインストールに失敗しました。メッセージに表示されたアンインストールログを確認してください。 |
| `Insufficient disk space.`                               | ディスクの空き容量を確保してください (新規インストールは 3.4 GB、移行は 2.4 GB)。  |
| `A newer version of UiPath Studio is already installed ...` | インストール済みのバージョンがチャネルのバージョンより新しいです。先にアンインストールしてください。 |
| `Installation failed with exit code N`                   | メッセージに表示されたインストールログを確認してください。                         |

古い Windows PowerShell で TLS が原因で `irm` が失敗する場合は、先に次のコマンドを実行してください。

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

## 参考資料

- [従来の MSI インストーラーからの移行](https://docs.uipath.com/ja/uipath-platform-installer/standalone/latest/user-guide/migrate-from-classic-msi)
- [コマンドラインからのインストール (UiPath Platform インストーラー)](https://docs.uipath.com/ja/uipath-platform-installer/standalone/latest/user-guide/install-from-the-command-line)
- [Studio のコマンドライン パラメーター (従来の MSI)](https://docs.uipath.com/ja/studio/standalone/2025.10/user-guide/command-line-parameters)
