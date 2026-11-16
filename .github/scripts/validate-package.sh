#!/usr/bin/env bash
# Run package validation under Windows PowerShell 5.1 in the shared custom job.
set -euo pipefail

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .github/scripts/Validate-Package.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .github/scripts/Test-PackageContents.ps1
