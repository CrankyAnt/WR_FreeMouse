#requires -Version 5.1
<#
    Test-PackageContents.ps1

    Release validation, part 2: the package must contain exactly the expected
    files, be internally version-consistent, and use the tested encoding.

    - Exact source allow-list: no test, scratch, or stray files.
    - Version consistency: the version lives ONLY in Package version.json, and
      (when a tag is given) that version matches the release tag.
    - Encoding: payload .ps1 are UTF-8 with a BOM and no CRLF; the other files
      are LF with no BOM.
#>
[CmdletBinding()]
param(
    [string]$PackageDir,
    [string]$ExpectedVersion = ''
)

$ErrorActionPreference = 'Stop'
if (-not $PackageDir) { $PackageDir = Join-Path $PSScriptRoot '..\..\package' }
$root = (Resolve-Path -LiteralPath $PackageDir).Path

function Get-RelativeFiles {
    param([string]$Base)
    Get-ChildItem -LiteralPath $Base -Recurse -File |
        ForEach-Object { $_.FullName.Substring($Base.Length).TrimStart('\') }
}

Write-Host '== Package allow-list =='
$expected = @(
    'WR FreeMouse Setup.cmd',
    'WR FreeMouse Setup.ps1',
    'Files\Package version.json',
    'Files\WR FreeMouse Runtime.ps1',
    'Files\WR FreeMouse Launch.ps1',
    'Files\WR FreeMouse Launch.vbs',
    'Files\WR FreeMouse Debug.cmd',
    'Files\WR FreeMouse Observer.ps1'
)
$actual = @(Get-RelativeFiles -Base $root)
$diff = Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)
if ($diff) {
    $diff | Where-Object SideIndicator -eq '=>' | ForEach-Object { Write-Host ("  unexpected: {0}" -f $_.InputObject) }
    $diff | Where-Object SideIndicator -eq '<=' | ForEach-Object { Write-Host ("  missing:    {0}" -f $_.InputObject) }
    throw 'Package contents do not match the expected allow-list.'
}
Write-Host ("Allow-list OK ({0} files)." -f $expected.Count)

Write-Host ''
Write-Host '== Version consistency =='
$manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'Files\Package version.json') | ConvertFrom-Json
$version = [string]$manifest.Version
if ([string]::IsNullOrWhiteSpace($version)) { throw 'Package version.json has no Version.' }
Write-Host ("Manifest version: {0}" -f $version)

# The version string must appear nowhere else in the payload.
$strays = @()
foreach ($rel in $actual) {
    if ($rel -eq 'Files\Package version.json') { continue }
    $text = Get-Content -Raw -LiteralPath (Join-Path $root $rel)
    if ($text -and $text.Contains($version)) { $strays += $rel }
}
if ($strays) {
    $strays | ForEach-Object { Write-Host ("  stray version in: {0}" -f $_) }
    throw "The version string appears outside Package version.json."
}
Write-Host 'Version is single-sourced in Package version.json.'

if ($ExpectedVersion) {
    $tagVersion = $ExpectedVersion -replace '^v', ''
    if ($tagVersion -ne $version) {
        throw ("Tag version ({0}) does not match manifest version ({1})." -f $tagVersion, $version)
    }
    Write-Host ("Tag/manifest match: {0}" -f $tagVersion)
}

Write-Host ''
Write-Host '== Encoding check =='
$bad = @()
foreach ($rel in $actual) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $rel))
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasCrlf = $false
    for ($i = 1; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A -and $bytes[$i - 1] -eq 0x0D) { $hasCrlf = $true; break }
    }
    $isPs1 = [System.IO.Path]::GetExtension($rel).ToLowerInvariant() -eq '.ps1'
    if ($hasCrlf) { $bad += "$rel : CRLF (expected LF)" }
    if ($isPs1 -and -not $hasBom) { $bad += "$rel : .ps1 missing UTF-8 BOM" }
    if (-not $isPs1 -and $hasBom) { $bad += "$rel : non-.ps1 has a BOM" }
}
if ($bad) {
    $bad | ForEach-Object { Write-Host ("  {0}" -f $_) }
    throw 'Encoding check failed.'
}
Write-Host 'Encoding OK (.ps1 = UTF-8 BOM + LF; others = LF, no BOM).'
