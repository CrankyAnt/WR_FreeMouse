#requires -Version 5.1
<#
    Build-Zip.ps1

    Assemble the public release ZIP from tracked source:

        WR-FreeMouse.zip
            <package/ payload at the archive root>
            README.md          (copied from the repo root - single source)
            CHANGELOG.md       (copied from the repo root - single source)
            LICENSE.md         (copied from the repo root - single source)
            REUSE.toml         (copied from the repo root - single source)

    The ZIP name is version-less on purpose: the version lives in the release
    tag, so the same asset name works for every release. Files are placed at
    the archive root (no wrapping folder). The assembled set is checked against
    an exact 12-file allow-list before zipping. Emits the ZIP path/name for the
    workflow when GITHUB_OUTPUT is set.
#>
[CmdletBinding()]
param(
    [string]$PackageDir,
    [string]$RepoRoot,
    [string]$OutDir,
    [string]$ZipName = 'WR-FreeMouse.zip'
)

$ErrorActionPreference = 'Stop'
if (-not $PackageDir) { $PackageDir = Join-Path $PSScriptRoot '..\..\package' }
if (-not $RepoRoot)   { $RepoRoot   = Join-Path $PSScriptRoot '..\..' }
if (-not $OutDir)     { $OutDir     = Join-Path $PSScriptRoot '..\..\dist' }

$staging = Join-Path $OutDir 'stage'
if (Test-Path -LiteralPath $staging) { Remove-Item -Recurse -Force -LiteralPath $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
# Normalize to absolute paths (the default OutDir contains '..\..'). The
# staging prefix must match each file's resolved FullName for the Substring
# below, and the emitted ZIP path must be free of '..' for the attestation.
$staging = (Resolve-Path -LiteralPath $staging).Path
$OutDir  = Split-Path -Parent $staging

Copy-Item -Recurse -Force -Path (Join-Path $PackageDir '*') -Destination $staging
$rootDocuments = @('README.md', 'CHANGELOG.md', 'LICENSE.md', 'REUSE.toml')
foreach ($doc in $rootDocuments) {
    Copy-Item -Force -LiteralPath (Join-Path $RepoRoot $doc) -Destination (Join-Path $staging $doc)
}

$expected = @(
    'README.md',
    'CHANGELOG.md',
    'LICENSE.md',
    'REUSE.toml',
    'WR FreeMouse Setup.cmd',
    'WR FreeMouse Setup.ps1',
    'Files\Package version.json',
    'Files\WR FreeMouse Runtime.ps1',
    'Files\WR FreeMouse Launch.ps1',
    'Files\WR FreeMouse Launch.vbs',
    'Files\WR FreeMouse Debug.cmd',
    'Files\WR FreeMouse Observer.ps1'
)
$actual = @(Get-ChildItem -LiteralPath $staging -Recurse -File |
    ForEach-Object { $_.FullName.Substring($staging.Length).TrimStart('\') })
$diff = Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)
if ($diff) {
    Write-Host ("Expected: {0}" -f ($expected -join ', '))
    Write-Host ("Actual:   {0}" -f ($actual -join ', '))
    throw 'Assembled package does not match the expected 12-file allow-list.'
}
Write-Host ("Assembled package OK ({0} files, root-level)." -f $expected.Count)

$zipPath = Join-Path $OutDir $ZipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -Force -LiteralPath $zipPath }

# Build the archive with forward-slash entry names (the ZIP spec). Windows
# PowerShell 5.1's Compress-Archive writes backslash separators, which some
# extractors mishandle; create the entries explicitly instead.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($rel in ($actual | Sort-Object)) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            (Join-Path $staging $rel),
            ($rel -replace '\\', '/'),
            [System.IO.Compression.CompressionLevel]::Optimal
        )
    }
}
finally {
    $zip.Dispose()
}
Write-Host ("Built: {0}" -f $zipPath)

if ($env:GITHUB_OUTPUT) {
    "zip=$zipPath"  | Out-File -Append -Encoding utf8 -FilePath $env:GITHUB_OUTPUT
    "name=$ZipName" | Out-File -Append -Encoding utf8 -FilePath $env:GITHUB_OUTPUT
}
