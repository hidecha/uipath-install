# uipath-install

[English](README.md) | 日本語

UiPath Studio を 1 行のコマンドでダウンロードし、サイレントインストールする PowerShell スクリプトです。

- 特定バージョン (例: `25.10.15`) または最新バージョンをインストール
- Robot のモードを **ユーザーモード** (既定) または **サービスモード** から選択
- Orchestrator URL を任意で設定
- 既存のインストールに対応: 古いバージョンはアップグレード、新しいバージョンはアンインストールしてからインストール

## 前提条件

- Windows PowerShell 5.1 または PowerShell 7.x
- **管理者として実行** した PowerShell (マシン単位でインストールするため)
- `raw.githubusercontent.com` と `download.uipath.com` へのインターネット接続

## クイックスタート

PowerShell を管理者として開き、次のコマンドを実行します。

```powershell
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

UiPath Studio の **最新バージョン** が **ユーザーモード** でインストールされます。

## オプション

| パラメーター       | 環境変数                  | 説明                                                                   | 既定値   |
| ------------------ | ------------------------- | ---------------------------------------------------------------------- | -------- |
| `-Version`         | `UIPATH_STUDIO_VERSION`   | インストールする Studio のバージョン (例: `25.10.15`)                  | 最新版   |
| `-Mode`            | `UIPATH_STUDIO_MODE`      | `User` (ユーザーモード) または `Service` (サービスモード)              | `User`   |
| `-OrchestratorUrl` | `UIPATH_ORCHESTRATOR_URL` | Orchestrator URL (インストーラーに `ORCHESTRATOR_URL` として渡されます) | (なし)   |

パラメーターは環境変数より優先されます。

`irm ... | iex` では引数を渡せないため、次のいずれかの方法を使用してください。

### 方法 1: 環境変数

```powershell
$env:UIPATH_STUDIO_VERSION = '25.10.15'
$env:UIPATH_STUDIO_MODE = 'Service'
irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1 | iex
```

### 方法 2: スクリプトブロックにパラメーターを渡す

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -Mode Service
```

Orchestrator URL を指定する場合:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hidecha/uipath-install/main/install.ps1))) -Version 25.10.15 -OrchestratorUrl https://cloud.uipath.com/myorg/mytenant/orchestrator_
```

## スクリプトの処理内容

1. MSI を `%TEMP%` にダウンロードします。
   - 特定バージョン: `https://download.uipath.com/versions/{Version}/UiPathStudio.msi`
   - 最新バージョン: `https://download.uipath.com/UiPathStudio.msi`
2. MSI からパッケージのバージョンを読み取り、既存の UiPath Studio のインストールを確認します
   (MSI の UpgradeCode で検出します)。

   | 既存のインストール         | 処理                                                     |
   | -------------------------- | -------------------------------------------------------- |
   | なし                       | 新規インストール                                         |
   | パッケージより古い         | 上書きでアップグレード                                   |
   | パッケージと同じバージョン | 何もしません (変更せずに終了します)                      |
   | パッケージより新しい       | 既存バージョンをアンインストールしてから新規インストール |

3. 次の機能を指定して `msiexec` をサイレント実行します。

   | モード   | `ADDLOCAL`                     |
   | -------- | ------------------------------ |
   | User     | `Studio,Robot`                 |
   | Service  | `Studio,Robot,RegisterService` |

   同等のコマンド:

   ```
   msiexec /i UiPathStudio.msi ADDLOCAL=Studio,Robot[,RegisterService] [ORCHESTRATOR_URL=...] /qn /norestart /l*v <log>
   ```

4. ダウンロードした MSI を削除し、インストールログのパス
   (`%TEMP%\UiPathStudio-install-<timestamp>.log`) を表示します。既存バージョンをアンインストールした場合、
   そのログは `%TEMP%\UiPathStudio-uninstall-<timestamp>.log` に保存されます。

システムが自動的に再起動されることはありません。再起動が必要な場合はメッセージが表示されます。

## トラブルシューティング

| メッセージ                                     | 原因 / 対処方法                                                                    |
| ---------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Administrator privileges are required.`       | PowerShell を管理者として実行してください。                                        |
| `Failed to download the installer ...`         | 指定したバージョンが存在しないか、ネットワークがブロックされています。バージョン番号を確認してください。 |
| `Failed to uninstall UiPath Studio ...`        | 既存の新しいバージョンのアンインストールに失敗しました。メッセージに表示されたアンインストールログを確認してください。 |
| `Installation failed with msiexec exit code N` | メッセージに表示されたインストールログを確認してください。                         |

古い Windows PowerShell で TLS が原因で `irm` が失敗する場合は、先に次のコマンドを実行してください。

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

## 参考資料

- [Studio のコマンドライン パラメーター](https://docs.uipath.com/ja/studio/standalone/2025.10/user-guide/command-line-parameters)
