#requires -Version 5.1
<#
    Validate-Package.ps1

    Release validation, part 1: prove the package is sound before it is built.

    - Parse every payload PowerShell script (catch syntax errors).
    - Extract and compile the actual WRFreeMouse C# core the same way Setup
      does at install time (marker-based), so a broken core fails the build
      rather than the user's machine.

    Runs under Windows PowerShell 5.1 / .NET Framework, so it must be invoked
    with `shell: powershell` on a Windows runner (and can be run locally the
    same way).
#>
[CmdletBinding()]
param(
    [string]$PackageDir
)

$ErrorActionPreference = 'Stop'
if (-not $PackageDir) { $PackageDir = Join-Path $PSScriptRoot '..\..\package' }

$payloadDir  = Join-Path $PackageDir 'Files'
$runtimePath = Join-Path $payloadDir 'WR FreeMouse Runtime.ps1'

Write-Host '== PowerShell syntax check =='
$hadError = $false
foreach ($script in @(Get-ChildItem -LiteralPath $PackageDir -Recurse -Filter *.ps1)) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count) {
        $hadError = $true
        Write-Host ("FAIL: {0}" -f $script.Name)
        $errors | ForEach-Object { Write-Host ("   L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    }
    else {
        Write-Host ("OK  : {0}" -f $script.Name)
    }
}
if ($hadError) { throw 'PowerShell syntax errors found.' }

Write-Host ''
Write-Host '== WRFreeMouse C# core compile =='

$source       = Get-Content -Raw -LiteralPath $runtimePath
$beginMarker  = '# WRFM_CORE_CSHARP_BEGIN'
$startMarker  = 'Add-Type -TypeDefinition @"'
$endMarker    = '"@ -ReferencedAssemblies $wrReferences'
$finishMarker = '# WRFM_CORE_CSHARP_END'

$begin = $source.IndexOf($beginMarker, [System.StringComparison]::Ordinal)
if ($begin -lt 0) { throw 'Could not find WRFM_CORE_CSHARP_BEGIN.' }

$finish = $source.IndexOf($finishMarker, $begin + $beginMarker.Length, [System.StringComparison]::Ordinal)
if ($finish -lt 0) { throw 'Could not find WRFM_CORE_CSHARP_END.' }

$start = $source.IndexOf($startMarker, $begin + $beginMarker.Length, [System.StringComparison]::Ordinal)
if ($start -lt 0 -or $start -ge $finish) { throw 'Could not find the core Add-Type start inside its markers.' }

$codeStart = $start + $startMarker.Length
$end = $source.IndexOf($endMarker, $codeStart, [System.StringComparison]::Ordinal)
if ($end -lt 0 -or $end -ge $finish) { throw 'Could not find the core Add-Type end inside its markers.' }

$code = $source.Substring($codeStart, $end - $codeStart)

# Guard against extracting the wrong block (the small probe or mixed source).
if ($code.IndexOf('public static class WRFreeMouse', [System.StringComparison]::Ordinal) -lt 0) {
    throw 'Extracted block is not the WRFreeMouse core.'
}
if ($code.IndexOf('WRGameWindowProbe', [System.StringComparison]::Ordinal) -ge 0 -or
    $code.IndexOf('Add-Type -TypeDefinition', [System.StringComparison]::Ordinal) -ge 0) {
    throw 'Extracted mixed/non-core source.'
}

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
$references = @(
    [System.Windows.Forms.Form].Assembly.Location,
    [System.Drawing.Bitmap].Assembly.Location
)
Add-Type -TypeDefinition $code -ReferencedAssemblies $references -ErrorAction Stop

Write-Host 'WRFreeMouse C# core compiled OK.'
