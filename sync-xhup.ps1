# Personal Xiaohe tables are text dictionaries, not a learned user database.
$XhupPersonalFiles = @(
    'xhup_dicts/xhup.user.dict.yaml',
    'xhup_dicts/xhup.user.top.dict.yaml'
)
$script:XhupPersonalCommitCreated = $false

function Get-XhupTextHash([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Test-XhupPersonalTable([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $parts = [regex]::Split($text, '(?m)^\.\.\.\s*$', 2)
    if ($parts.Count -ne 2 -or $parts[0] -notmatch '(?m)^name:\s*xhup\.user(?:\.top)?\s*$') {
        throw "Invalid Xiaohe personal table header: $Path"
    }
    foreach ($line in ($parts[1] -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -notmatch "^[^`t]+`t[a-z;']{1,4}(`t[0-9]+)?\s*$") {
            throw "Invalid Xiaohe personal entry (use text, TAB, 1-4 letter code): $Path"
        }
    }
}

function Save-XhupPersonalEntries([string]$RepoDir, [string]$RimeDir) {
    $stateFile = Join-Path $RimeDir '.xhup-personal-sync.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
    }
    $pending = @()
    # Validate both files and all conflicts before copying either one.
    foreach ($relativePath in $XhupPersonalFiles) {
        $repoFile = Join-Path $RepoDir $relativePath
        $liveFile = Join-Path $RimeDir $relativePath
        if (-not (Test-Path -LiteralPath $repoFile)) { throw "Missing Xiaohe personal table: $repoFile" }
        Test-XhupPersonalTable $repoFile
        if (-not (Test-Path -LiteralPath $liveFile)) { continue }
        Test-XhupPersonalTable $liveFile
        $repoHash = Get-XhupTextHash $repoFile
        $liveHash = Get-XhupTextHash $liveFile
        if ($repoHash -eq $liveHash) { continue }
        $baseline = $null
        if ($null -ne $state -and $null -ne $state.PSObject.Properties['files']) {
            $property = $state.files.PSObject.Properties[$relativePath]
            if ($null -ne $property) { $baseline = [string]$property.Value }
        }
        if (-not $baseline) {
            throw "Xiaohe personal table differs without a sync baseline. Preserve and merge both copies before syncing: $relativePath"
        }
        if ($liveHash -ne $baseline) {
            if ($repoHash -ne $baseline) {
                throw "Xiaohe personal table changed in both locations. Preserve and merge both copies before syncing: $relativePath"
            }
            $pending += $relativePath
        }
        # If only the repository changed, install its version after pulling.
    }
    foreach ($relativePath in $pending) {
        Copy-Item -LiteralPath (Join-Path $RimeDir $relativePath) -Destination (Join-Path $RepoDir $relativePath) -Force
    }
    return $pending
}

function Write-XhupPersonalBaseline([string]$RimeDir) {
    $hashes = [ordered]@{}
    foreach ($relativePath in $XhupPersonalFiles) {
        $path = Join-Path $RimeDir $relativePath
        Test-XhupPersonalTable $path
        $hashes[$relativePath] = Get-XhupTextHash $path
    }
    $state = [ordered]@{ version = 1; files = $hashes }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $RimeDir '.xhup-personal-sync.json'), (($state | ConvertTo-Json -Depth 4) + "`n"), $utf8)
}

function Invoke-XhupRepositoryPull([string]$RepoDir, [switch]$LocalOnly) {
    $dirty = @(& git -C $RepoDir diff --name-only HEAD --)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect tracked Git changes.' }
    $unrelated = @($dirty | Where-Object { $_ -notin $XhupPersonalFiles })
    if ($unrelated.Count -gt 0) { throw 'The repository has tracked local changes. Commit or stash them before syncing.' }
    if ($dirty.Count -gt 0) {
        if ($LocalOnly) {
            Write-Host 'Personal Xiaohe edits saved locally; pull skipped in LocalOnly mode.'
            return
        }
        # Commit only these personal files before merging other devices' edits.
        Invoke-Git -Arguments (@('add', '--') + $dirty)
        Invoke-Git -Arguments (@('commit', '-m', 'sync Xiaohe personal dictionaries', '--') + $dirty)
        $script:XhupPersonalCommitCreated = $true
    }
    # Preserve existing local commits and prior conflict resolutions.
    Invoke-Git -Arguments @('pull', '--no-rebase', '--no-edit', 'origin', 'main')
}
