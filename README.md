# Rime user data sync

This repository stores the Rime configuration used by Weasel on Windows and
plain-text user dictionary snapshots for multiple devices.

## First use on a new Windows device

1. Install [Git for Windows](https://git-scm.com/download/win) and Weasel.
2. Run Weasel once so that `%APPDATA%\Rime` and `installation.yaml` are created.
3. Clone this repository and run the synchronization script:

```powershell
git clone git@github.com:jiangescn/rime-userdb.git "$env:USERPROFILE\rime-userdb"
Set-Location "$env:USERPROFILE\rime-userdb"
powershell -ExecutionPolicy Bypass -File .\sync-rime.ps1
```

The script pulls `main`, exports the current local user dictionary, backs up
the existing portable configuration, installs the repository configuration,
imports all device snapshots, redeploys Weasel, and pushes the merged snapshot
for the current device back to GitHub.

Each device must keep its own `installation_id`. Do not copy
`installation.yaml` from another device. Compiled `*.userdb` and `build`
directories are intentionally not stored in Git.

## Later synchronization

Run the same command whenever this device needs to exchange learned words with
the other devices:

```powershell
powershell -ExecutionPolicy Bypass -File .\sync-rime.ps1
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
```
