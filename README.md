# Rime user data sync

This repository stores the Rime configuration used by Weasel on Windows and
plain-text user dictionary snapshots for multiple devices.

## First use on a new Windows device

1. Install [Git for Windows](https://git-scm.com/download/win) and Weasel.
2. Run Weasel once so that `%APPDATA%\Rime` and `installation.yaml` are created.
3. Download and run the bootstrap script:

```powershell
$bootstrap = Join-Path $env:TEMP "sync-rime.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/jiangescn/rime-userdb/main/sync-rime.ps1" -OutFile $bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File $bootstrap
```

The standalone script clones or updates the repository at
`%LOCALAPPDATA%\rime-userdb`, then installs the configuration into Weasel's
default `%APPDATA%\Rime` user directory. It exports the current local user
dictionary, backs up the existing portable configuration, imports all device
snapshots, redeploys Weasel, and pushes the merged snapshot for the current
device back to GitHub.

Each device must keep its own `installation_id`. Do not copy
`installation.yaml` from another device. Compiled `*.userdb` and `build`
directories are intentionally not stored in Git.

## Later synchronization

Run the same command whenever this device needs to exchange learned words with
the other devices:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\rime-userdb\sync-rime.ps1"
```

Backups are saved under `%LOCALAPPDATA%\RimeBackups`.

Useful options:

```powershell
# Update only local Rime; do not commit or push a snapshot.
.\sync-rime.ps1 -LocalOnly

# Skip git pull, useful for local testing.
.\sync-rime.ps1 -SkipPull -LocalOnly

# Use a non-default Rime directory or deployer executable.
.\sync-rime.ps1 -RimeDir "D:\Rime" -DeployerPath "C:\path\WeaselDeployer.exe"

# Store the managed Git checkout somewhere else.
.\sync-rime.ps1 -CheckoutDir "D:\rime-userdb"
```
