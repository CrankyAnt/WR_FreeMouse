#!/usr/bin/env bash
# Release hook of the shared part github-release: validate the package for the
# tag, then build the release ZIP at dist/WR-FreeMouse.zip.
set -euo pipefail

tag="${GITHUB_REF_NAME:?the release tag is not set}"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .github/scripts/Validate-Package.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .github/scripts/Test-PackageContents.ps1 -ExpectedVersion "$tag"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .github/scripts/Build-Zip.ps1
