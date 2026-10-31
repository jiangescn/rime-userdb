# Shared file synchronization and device-local frontend appearance.
function Get-RimeFileHash([string]$Path) {
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.ico','.ocd2')) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Initialize-RimeFileSync([string]$RepoDir, [string]$RimeDir, [string]$Platform = 'windows') {
    $script:RimeManifest = [IO.File]::ReadAllText((Join-Path $RepoDir 'rime-files.json')) | ConvertFrom-Json
    if ($RimeManifest.version -ne 1) { throw 'Unsupported Rime file manifest.' }
    $script:RimeCommonFiles = @($RimeManifest.common_files)
    $script:RimePlatformFiles = @($RimeManifest.platform_files.$Platform)
    $script:RimeAppearanceFiles = @($RimeManifest.appearance_files.$Platform)
    foreach ($path in @($RimeCommonFiles) + @($RimePlatformFiles)) {
        if ($path -notmatch '^[a-zA-Z0-9_./-]+$' -or $path -match '(^|/)\.\.(/|$)' -or $path.StartsWith('/')) { throw "Unsafe managed path: $path" }
        if (-not (Test-Path -LiteralPath (Join-Path $RepoDir $path) -PathType Leaf)) { throw "Required repository file missing: $path" }
    }
    $installation = Join-Path $RimeDir 'installation.yaml'
    if (-not (Test-Path -LiteralPath $installation)) {
        $id = [guid]::NewGuid().ToString()
        [IO.File]::WriteAllText($installation, ('installation_id: "' + $id + '"' + "`n"), (New-Object Text.UTF8Encoding($false)))
    }
    $text = [IO.File]::ReadAllText($installation)
    if ($text -notmatch '(?m)^\s*installation_id:\s*["'']?([a-zA-Z0-9_.-]+)["'']?\s*$' -or $Matches[1] -in @('.','..')) { throw 'Invalid or missing Rime installation_id.' }
    $script:RimeDeviceId = $Matches[1]
    $script:RimeProfilePrefix = 'devices/' + $RimeDeviceId + '/appearance/'
    $script:RimeState = $null
    $stateFile = Join-Path $RimeDir '.rime-sync-state.json'
    if (Test-Path -LiteralPath $stateFile) { $script:RimeState = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json }
    $script:RimeConfigCommitCreated = $false
}

function Get-RimeBaselineHash([string]$Path) {
    if ($null -ne $RimeState) {
        $entry = $RimeState.files.PSObject.Properties[$Path]
        if ($null -ne $entry) { return [string]$entry.Value }
    }
    $entry = $RimeManifest.initial_hashes.PSObject.Properties[$Path]
    if ($null -ne $entry) { return [string]$entry.Value }
    return $null
}

function Get-RimeManagedCommitPaths {
    return @($RimeCommonFiles) + @($RimePlatformFiles | Where-Object { $_ -notin $RimeAppearanceFiles }) + @($RimeAppearanceFiles | ForEach-Object { $RimeProfilePrefix + $_ }) + @('devices/' + $RimeDeviceId + '/device.json')
}

function Save-RimeLocalChanges([string]$RepoDir, [string]$RimeDir) {
    $pending = @()
    foreach ($relative in @($RimeCommonFiles) + @($RimePlatformFiles | Where-Object { $_ -notin $RimeAppearanceFiles })) {
        $live = Join-Path $RimeDir $relative
        $repo = Join-Path $RepoDir $relative
        if (-not (Test-Path -LiteralPath $live)) { continue }
        if ($relative -in $XhupPersonalFiles) { Test-XhupPersonalTable $live; Test-XhupPersonalTable $repo }
        $liveHash = Get-RimeFileHash $live
        $repoHash = Get-RimeFileHash $repo
        if ($liveHash -eq $repoHash) { continue }
        $baseline = Get-RimeBaselineHash $relative
        if (-not $baseline) { throw "Existing local file differs without a sync baseline. Preserve and merge both copies: $relative" }
        if ($liveHash -ne $baseline) {
            if ($repoHash -ne $baseline) { throw "File changed in both locations. Preserve and merge both copies: $relative" }
            $pending += [pscustomobject]@{Source=$live;Destination=$repo;Relative=$relative}
        }
    }
    foreach ($relative in $RimeAppearanceFiles) {
        $live = Join-Path $RimeDir $relative
        $profileRelative = $RimeProfilePrefix + $relative
        $profile = Join-Path $RepoDir $profileRelative
        if (Test-Path -LiteralPath $live) {
            if (Test-Path -LiteralPath $profile) {
                $liveHash = Get-RimeFileHash $live
                $profileHash = Get-RimeFileHash $profile
                if ($liveHash -eq $profileHash) { continue }
                $baseline = Get-RimeBaselineHash $relative
                if (-not $baseline) { throw "Device appearance differs without a sync baseline: $relative" }
                if ($liveHash -eq $baseline) { continue }
                if ($profileHash -ne $baseline) { throw "Device appearance changed in both locations: $relative" }
            }
            $source = $live
        } else {
            if (Test-Path -LiteralPath $profile) { continue }
            $source = Join-Path $RepoDir $relative
        }
        $pending += [pscustomobject]@{Source=$source;Destination=$profile;Relative=$profileRelative}
    }
    # Resolve every conflict first; never partially overwrite personal settings.
    foreach ($item in $pending) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.Destination) -Force | Out-Null
        Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force
    }
    $metadata = Join-Path $RepoDir ('devices/' + $RimeDeviceId + '/device.json')
    if (-not (Test-Path -LiteralPath $metadata)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $metadata) -Force | Out-Null
        [IO.File]::WriteAllText($metadata, (([ordered]@{platform='windows';appearance='appearance/'} | ConvertTo-Json) + "`n"), (New-Object Text.UTF8Encoding($false)))
    }
    return @($pending | ForEach-Object { $_.Relative })
}

function Install-RimeDeviceAppearance([string]$RepoDir, [string]$RimeDir) {
    foreach ($relative in $RimeAppearanceFiles) {
        $profile = Join-Path $RepoDir ($RimeProfilePrefix + $relative)
        if (-not (Test-Path -LiteralPath $profile)) { throw "Device appearance is missing: $profile" }
        Copy-Item -LiteralPath $profile -Destination (Join-Path $RimeDir $relative) -Force
    }
}

function Write-RimeSyncState([string]$RimeDir) {
    $hashes = [ordered]@{}
    foreach ($relative in @($RimeCommonFiles) + @($RimePlatformFiles)) {
        $hashes[$relative] = Get-RimeFileHash (Join-Path $RimeDir $relative)
    }
    $state = [ordered]@{version=1;files=$hashes}
    [IO.File]::WriteAllText((Join-Path $RimeDir '.rime-sync-state.json'), (($state | ConvertTo-Json -Depth 4) + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-RimeRepositoryPull([string]$RepoDir, [switch]$LocalOnly) {
    $allowed = @(Get-RimeManagedCommitPaths)
    $tracked = @(& git -C $RepoDir diff --name-only HEAD --)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect tracked Git changes.' }
    if (@($tracked | Where-Object { $_ -notin $allowed }).Count) { throw 'The repository has unrelated tracked changes. Commit or stash them before syncing.' }
    $new = @(& git -C $RepoDir ls-files --others --exclude-standard -- @allowed)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect new configuration files.' }
    $changed = @($tracked) + @($new)
    if ($changed.Count) {
        if ($LocalOnly) { Write-Host 'Local settings saved; pull skipped in LocalOnly mode.'; return }
        Invoke-Git -Arguments (@('add','--') + $changed)
        Invoke-Git -Arguments (@('commit','-m','sync personal Rime settings','--') + $changed)
        $script:RimeConfigCommitCreated = $true
    }
    # Keep the existing merge-based pull behavior and all existing local history.
    Invoke-Git -Arguments @('pull','--no-rebase','--no-edit','origin','main')
}
