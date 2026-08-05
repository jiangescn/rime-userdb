[CmdletBinding()]
param(
    [string]$RimeDir = (Join-Path $env:APPDATA "Rime"),
    [string]$DeployerPath,
    [switch]$SkipPull,
    [switch]$LocalOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoDir = $PSScriptRoot
$ConfigFiles = @(
    "default.custom.yaml",
    "double_pinyin_flypy.custom.yaml",
    "weasel.custom.yaml",
    "rime.lua",
    "rime_ice.dict.yaml",
    "rime_ice.schema.yaml",
    "word_simp.dict.yaml",
    "word_simp.schema.yaml",
    "cn.ico",
    "en.ico"
)
$ConfigDirectories = @("cn_dicts", "en_dicts")

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & git -C $RepoDir @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Deployer {
    param([Parameter(Mandatory = $true)][string]$Argument)

    Write-Host "Running WeaselDeployer.exe $Argument ..."
    # Weasel 0.17.4 compares the raw command line exactly. Start-Process adds a
    # trailing space in Windows PowerShell 5, which makes /sync open the normal
    # settings dialog instead. ProcessStartInfo preserves the exact argument.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $DeployerPath
    $startInfo.Arguments = $Argument
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "WeaselDeployer.exe $Argument failed with exit code $($process.ExitCode)"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoDir ".git"))) {
    throw "Run this script from a Git clone of the rime-userdb repository."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found in PATH. Install Git for Windows first."
}

if (-not $DeployerPath) {
    $searchRoots = @()
    if ($env:ProgramFiles) {
        $searchRoots += (Join-Path $env:ProgramFiles "Rime")
    }
    if (${env:ProgramFiles(x86)}) {
        $searchRoots += (Join-Path ${env:ProgramFiles(x86)} "Rime")
    }

    $DeployerPath = $searchRoots |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter "WeaselDeployer.exe" -File -Recurse -ErrorAction SilentlyContinue
        } |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $DeployerPath -or -not (Test-Path -LiteralPath $DeployerPath)) {
    throw "WeaselDeployer.exe was not found. Install Weasel or pass -DeployerPath explicitly."
}

New-Item -ItemType Directory -Path $RimeDir -Force | Out-Null

if (-not $SkipPull) {
    $dirtyTrackedFiles = @(& git -C $RepoDir status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect the Git working tree."
    }
    if ($dirtyTrackedFiles.Count -gt 0) {
        throw "The repository has tracked local changes. Commit or stash them before syncing."
    }
    Invoke-Git -Arguments @("pull", "--rebase", "origin", "main")
}

# Export the current database before importing snapshots from other devices.
Invoke-Deployer -Argument "/sync"

$backupRoot = Join-Path $env:LOCALAPPDATA "RimeBackups"
$backupDir = Join-Path $backupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

foreach ($relativePath in $ConfigFiles) {
    $source = Join-Path $RimeDir $relativePath
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $backupDir $relativePath) -Force
    }
}
foreach ($relativePath in $ConfigDirectories) {
    $source = Join-Path $RimeDir $relativePath
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $backupDir -Recurse -Force
    }
}
$localSyncDir = Join-Path $RimeDir "sync"
if (Test-Path -LiteralPath $localSyncDir) {
    Copy-Item -LiteralPath $localSyncDir -Destination $backupDir -Recurse -Force
}

foreach ($relativePath in $ConfigFiles) {
    $source = Join-Path $RepoDir $relativePath
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required repository file is missing: $relativePath"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $RimeDir $relativePath) -Force
}
foreach ($relativePath in $ConfigDirectories) {
    $source = Join-Path $RepoDir $relativePath
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required repository directory is missing: $relativePath"
    }
    Copy-Item -LiteralPath $source -Destination $RimeDir -Recurse -Force
}

New-Item -ItemType Directory -Path $localSyncDir -Force | Out-Null
$repoSyncDir = Join-Path $RepoDir "sync"
if (Test-Path -LiteralPath $repoSyncDir) {
    foreach ($deviceDirectory in Get-ChildItem -LiteralPath $repoSyncDir -Directory) {
        $snapshot = Join-Path $deviceDirectory.FullName "rime_ice.userdb.txt"
        if (Test-Path -LiteralPath $snapshot) {
            $destination = Join-Path $localSyncDir $deviceDirectory.Name
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -LiteralPath $snapshot -Destination (Join-Path $destination "rime_ice.userdb.txt") -Force
        }
    }
}

Invoke-Deployer -Argument "/deploy"
Invoke-Deployer -Argument "/sync"
Invoke-Deployer -Argument "/deploy"

$installationFile = Join-Path $RimeDir "installation.yaml"
if (-not (Test-Path -LiteralPath $installationFile)) {
    throw "Rime did not create installation.yaml."
}
$installationText = Get-Content -LiteralPath $installationFile -Raw
if ($installationText -notmatch '(?m)^\s*installation_id:\s*"?([^"\r\n]+)"?\s*$') {
    throw "Unable to read installation_id from installation.yaml."
}
$installationId = $Matches[1].Trim()
$localSnapshot = Join-Path $localSyncDir "$installationId\rime_ice.userdb.txt"
if (-not (Test-Path -LiteralPath $localSnapshot)) {
    throw "Rime did not export the expected user dictionary snapshot: $localSnapshot"
}

if ($LocalOnly) {
    Write-Host "Local Rime synchronization completed."
    Write-Host "Backup: $backupDir"
    exit 0
}

$repoDeviceDir = Join-Path $repoSyncDir $installationId
New-Item -ItemType Directory -Path $repoDeviceDir -Force | Out-Null
$repoSnapshot = Join-Path $repoDeviceDir "rime_ice.userdb.txt"
Copy-Item -LiteralPath $localSnapshot -Destination $repoSnapshot -Force

$gitSnapshot = "sync/$installationId/rime_ice.userdb.txt"
Invoke-Git -Arguments @("add", "--", $gitSnapshot)
& git -C $RepoDir diff --cached --quiet --exit-code
$diffExitCode = $LASTEXITCODE
if ($diffExitCode -eq 1) {
    $commitMessage = "sync Rime user dictionary from $env:COMPUTERNAME"
    Invoke-Git -Arguments @("commit", "-m", $commitMessage)
    Invoke-Git -Arguments @("push", "origin", "main")
} elseif ($diffExitCode -ne 0) {
    throw "Unable to inspect staged Git changes."
} else {
    Write-Host "The GitHub snapshot is already up to date."
}

Write-Host "Rime and GitHub synchronization completed."
Write-Host "Device ID: $installationId"
Write-Host "Backup: $backupDir"
