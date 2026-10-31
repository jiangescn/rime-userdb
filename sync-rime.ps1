[CmdletBinding()]
param(
    [string]$RimeDir = (Join-Path $env:APPDATA "Rime"),
    [string]$DeployerPath,
    [string]$CheckoutDir = (Join-Path $env:LOCALAPPDATA "rime-userdb"),
    [string]$RepositoryUrl = "git@github.com:jiangescn/rime-userdb.git",
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
    "en.ico",
    "xhup.schema.yaml",
    "xhup.dict.yaml",
    "xhup_reverse.schema.yaml",
    "xhup_reverse.dict.yaml",
    "xhup.custom.yaml",
    "lua/xhup/common.lua",
    "lua/xhup/date_translator.lua",
    "lua/xhup/time_translator.lua",
    "lua/xhup/shortcut_processor.lua",
    "lua/xhup/shortcut_translator.lua",
    "opencc/short_hints.json",
    "opencc/short_hints.txt"
)
$ConfigDirectories = @("cn_dicts", "en_dicts", "xhup_dicts")

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found in PATH. Install Git for Windows first."
}

# A standalone downloaded copy of this script bootstraps a managed checkout,
# then hands control to the repository copy so all remaining files are trusted
# to come from the same revision.
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir ".git"))) {
    $checkoutGitDir = Join-Path $CheckoutDir ".git"
    if (Test-Path -LiteralPath $CheckoutDir) {
        if (-not (Test-Path -LiteralPath $checkoutGitDir)) {
            throw "CheckoutDir exists but is not a Git repository: $CheckoutDir"
        }

        $remoteOutput = @(& git -C $CheckoutDir remote get-url origin)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read the origin remote in $CheckoutDir"
        }
        $actualRemote = ($remoteOutput -join "`n").Trim()
        $normalizedActual = (($actualRemote -replace '^git@github\.com:', 'https://github.com/') -replace '\.git$', '').TrimEnd('/').ToLowerInvariant()
        $normalizedExpected = (($RepositoryUrl -replace '^git@github\.com:', 'https://github.com/') -replace '\.git$', '').TrimEnd('/').ToLowerInvariant()
        if ($normalizedActual -ne $normalizedExpected) {
            throw "CheckoutDir points to a different repository: $actualRemote"
        }
    } else {
        Write-Host "Cloning $RepositoryUrl to $CheckoutDir ..."
        & git clone $RepositoryUrl $CheckoutDir
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to clone $RepositoryUrl"
        }
    }

    $repositoryScript = Join-Path $CheckoutDir "sync-rime.ps1"
    if (-not (Test-Path -LiteralPath $repositoryScript)) {
        throw "The cloned repository does not contain sync-rime.ps1."
    }

    $childArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $repositoryScript,
        "-RimeDir", $RimeDir,
        "-CheckoutDir", $CheckoutDir,
        "-RepositoryUrl", $RepositoryUrl
    )
    if ($DeployerPath) {
        $childArguments += @("-DeployerPath", $DeployerPath)
    }
    if ($SkipPull) {
        $childArguments += "-SkipPull"
    }
    if ($LocalOnly) {
        $childArguments += "-LocalOnly"
    }

    & powershell.exe @childArguments
    exit $LASTEXITCODE
}

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

. (Join-Path $RepoDir 'sync-xhup.ps1')
$xhupPersonalChanges = @(Save-XhupPersonalEntries -RepoDir $RepoDir -RimeDir $RimeDir)
if (-not $SkipPull) {
    Invoke-XhupRepositoryPull -RepoDir $RepoDir -LocalOnly:$LocalOnly
}

# Export the current database before importing snapshots from other devices.
Invoke-Deployer -Argument "/sync"

$backupRoot = Join-Path $env:LOCALAPPDATA "RimeBackups"
$backupDir = Join-Path $backupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

foreach ($relativePath in $ConfigFiles) {
    $source = Join-Path $RimeDir $relativePath
    if (Test-Path -LiteralPath $source) {
        $backupFile = Join-Path $backupDir $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupFile) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $backupFile -Force
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
    $destinationFile = Join-Path $RimeDir $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destinationFile) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destinationFile -Force
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

Write-XhupPersonalBaseline -RimeDir $RimeDir

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
$commitPaths = @($gitSnapshot) + @($XhupPersonalFiles)
Invoke-Git -Arguments (@("add", "--") + $commitPaths)
& git -C $RepoDir diff --cached --quiet --exit-code -- @commitPaths
$diffExitCode = $LASTEXITCODE
if ($diffExitCode -eq 1) {
    $commitMessage = "sync Rime user dictionary from $env:COMPUTERNAME"
    Invoke-Git -Arguments (@("commit", "-m", $commitMessage, "--") + $commitPaths)
    Invoke-Git -Arguments @("push", "origin", "main")
} elseif ($diffExitCode -ne 0) {
    throw "Unable to inspect staged Git changes."
} else {
    if ($XhupPersonalCommitCreated) {
        Invoke-Git -Arguments @("push", "origin", "main")
    }
    Write-Host "The GitHub snapshot is already up to date."
}

Write-Host "Rime and GitHub synchronization completed."
Write-Host "Device ID: $installationId"
Write-Host "Backup: $backupDir"
