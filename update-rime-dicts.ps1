[CmdletBinding()]
param(
    [string]$RepoDir = $PSScriptRoot,
    [string]$BackupRoot = (Join-Path $env:LOCALAPPDATA 'RimeBackups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestName = 'rime-ice-update.json'
$versionName = 'RIME_ICE_VERSION.md'
function Get-DictionaryHash([string]$Path) {
    # Git for Windows may use CRLF in a checkout while GitHub ZIPs use LF.
    # Compare canonical UTF-8 text so a fresh checkout is not mistaken for edits.
    $content = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}
$dictionaryPaths = @(
    'cn_dicts/41448.dict.yaml', 'cn_dicts/8105.dict.yaml',
    'cn_dicts/base.dict.yaml', 'cn_dicts/ext.dict.yaml',
    'cn_dicts/others.dict.yaml', 'cn_dicts/tencent.dict.yaml',
    'en_dicts/cn_en_abc.txt', 'en_dicts/cn_en_double_pinyin.txt',
    'en_dicts/cn_en_flypy.txt', 'en_dicts/cn_en_jiajia.txt',
    'en_dicts/cn_en_mspy.txt', 'en_dicts/cn_en_sogou.txt',
    'en_dicts/cn_en_ziguang.txt', 'en_dicts/cn_en.txt',
    'en_dicts/en_ext.dict.yaml', 'en_dicts/en.dict.yaml'
)
$manifest = Get-Content -LiteralPath (Join-Path $RepoDir $manifestName) -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.source -ne 'https://github.com/iDvel/rime-ice' -or
    $manifest.commit -notmatch '^[a-f0-9]{40}$' -or $manifest.hashFormat -ne 'sha256-utf8-lf') {
    throw 'Invalid official dictionary manifest.'
}

# Refuse to overwrite hand-edited dictionaries, including edits committed to Git.
foreach ($relativePath in $dictionaryPaths) {
    $property = $manifest.files.PSObject.Properties[$relativePath]
    $target = Join-Path $RepoDir $relativePath
    if (-not $property -or -not (Test-Path -LiteralPath $target) -or
        (Get-DictionaryHash $target) -ne $property.Value) {
        throw "Dictionary differs from its recorded upstream copy: $relativePath. Keep the local edit; automatic update skipped."
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$head = Invoke-RestMethod -Uri 'https://api.github.com/repos/iDvel/rime-ice/commits/HEAD' -Headers @{
    'User-Agent' = 'RimeDictionarySync'
    'Accept' = 'application/vnd.github+json'
} -TimeoutSec 30
$revision = [string]$head.sha
if ($revision -notmatch '^[a-f0-9]{40}$') { throw 'GitHub returned an invalid commit ID.' }
if ($revision -eq $manifest.commit) {
    Write-Host "Official dictionaries already checked at $revision."
    return [pscustomobject]@{ ChangedPaths = @(); BackupDirectory = $null }
}

$temporaryDir = Join-Path ([IO.Path]::GetTempPath()) ('rime-ice-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDir | Out-Null
$archive = $null
$backupDirectory = $null
$changedPaths = @()
try {
    $zipPath = Join-Path $temporaryDir 'upstream.zip'
    Write-Host "Downloading official dictionaries at $revision ..."
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/iDvel/rime-ice/zip/$revision" -OutFile $zipPath -TimeoutSec 180 | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $hashes = [ordered]@{}
    foreach ($relativePath in $dictionaryPaths) {
        # Extract only exact allowlisted entries; never run or install upstream code.
        $entry = $archive.GetEntry("rime-ice-$revision/$relativePath")
        if (-not $entry -or $entry.Length -lt 100 -or $entry.Length -gt 100MB) {
            throw "Missing or unexpectedly sized official dictionary: $relativePath"
        }
        $stagedFile = Join-Path $temporaryDir $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $stagedFile) -Force | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $stagedFile)
        # base.dict.yaml contains several thousand lines of editorial comments.
        $reader = New-Object IO.StreamReader($stagedFile, [Text.Encoding]::UTF8, $true)
        try {
            $header = @(for ($lineNumber = 0; $lineNumber -lt 20000 -and -not $reader.EndOfStream; $lineNumber++) {
                $line = $reader.ReadLine()
                $line
                if ($line -match '^\.\.\.\s*$' -or (-not $relativePath.EndsWith('.dict.yaml') -and $line -match "`t")) { break }
            })
        } finally { $reader.Dispose() }
        if ($relativePath.EndsWith('.dict.yaml')) {
            $expectedName = [IO.Path]::GetFileName($relativePath) -replace '\.dict\.yaml$', ''
            if (-not ($header -match ('^name:\s*["'']?' + [regex]::Escape($expectedName) + '["'']?\s*$')) -or
                -not ($header -match '^\.\.\.\s*$')) {
                throw "Invalid Rime dictionary header: $relativePath"
            }
        } elseif (-not ($header -match "`t")) {
            throw "Invalid tab-separated dictionary: $relativePath"
        }
        $hashes[$relativePath] = Get-DictionaryHash $stagedFile
        if ($hashes[$relativePath] -ne $manifest.files.PSObject.Properties[$relativePath].Value) {
            $changedPaths += $relativePath
        }
    }
    $archive.Dispose()
    $archive = $null

    $newManifest = [ordered]@{
        source = 'https://github.com/iDvel/rime-ice'
        commit = $revision
        hashFormat = 'sha256-utf8-lf'
        files = $hashes
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $temporaryDir $manifestName), (($newManifest | ConvertTo-Json -Depth 4) + "`n"), $utf8)
    $versionText = @"
# Rime Ice dictionary version

- Source: https://github.com/iDvel/rime-ice
- Upstream commit: ``$revision``
- Upstream commit time: $($head.commit.committer.date)
- Updated at (UTC): $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
- Scope: the 16 dictionary files listed in ``rime-ice-update.json``.

The root dictionary import list, schemas, Lua, custom configuration and personal
word frequencies are preserved. New or renamed upstream files require review.
"@
    [IO.File]::WriteAllText((Join-Path $temporaryDir $versionName), $versionText, $utf8)
    $changedPaths += @($manifestName, $versionName)

    # Prepare and verify the entire backup before the first replacement.
    $backupDirectory = Join-Path $BackupRoot ('official-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    foreach ($relativePath in $changedPaths) {
        $backupFile = Join-Path $backupDirectory $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupFile) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoDir $relativePath) -Destination $backupFile
        if ((Get-FileHash -LiteralPath $backupFile).Hash -ne (Get-FileHash -LiteralPath (Join-Path $RepoDir $relativePath)).Hash) {
            throw "Backup verification failed: $relativePath"
        }
    }
    $replacementStarted = $false
    try {
        $replacementStarted = $true
        foreach ($relativePath in $changedPaths) {
            $target = Join-Path $RepoDir $relativePath
            Copy-Item -LiteralPath (Join-Path $temporaryDir $relativePath) -Destination $target -Force
            if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath (Join-Path $temporaryDir $relativePath)).Hash) {
                throw "Installed dictionary verification failed: $relativePath"
            }
        }
    } catch {
        $replacementError = $_
        try {
            if ($replacementStarted) {
                foreach ($relativePath in $changedPaths) {
                    Copy-Item -LiteralPath (Join-Path $backupDirectory $relativePath) -Destination (Join-Path $RepoDir $relativePath) -Force
                }
            }
        } catch {
            $_.Exception.Data['RollbackFailed'] = $true
            throw
        }
        throw $replacementError
    }
    Write-Host "Official dictionary update prepared. Backup: $backupDirectory"
    return [pscustomobject]@{ ChangedPaths = $changedPaths; BackupDirectory = $backupDirectory }
} finally {
    if ($archive) { $archive.Dispose() }
    # This path is a fresh GUID child of the system temporary directory.
    $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDir)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTemporary.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemporary) -match '^rime-ice-[a-f0-9]{32}$') {
        try { Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force }
        catch { Write-Warning "Unable to remove download staging directory: $resolvedTemporary" }
    }
}
