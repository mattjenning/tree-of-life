# deploy.ps1 — unpacks tol_update.zip and copies files into the project.
#
# Usage:
#   From a PowerShell window:
#     cd "D:\Projects\Tree of Life"
#     .\deploy.ps1
#
# What it does:
#   1. Looks in D:\downloads for the newest tol_update*.zip
#   2. Extracts it to a temp folder
#   3. Copies src/ from the zip into D:\Projects\Tree of Life\src/
#      (overwriting existing files — the zip always contains the full
#      current state, not a diff)
#   4. Shows what changed via git status
#
# Idempotent — running it twice does nothing bad. The zip always
# represents the complete current state.

$ErrorActionPreference = "Stop"

$ProjectRoot = "D:\Projects\Tree of Life"
$DownloadsDir = "D:\downloads"
$ZipPattern = "tol_update*.zip"

# --- 1. Find the newest matching zip ---------------------------------
Write-Host "Looking for $ZipPattern in $DownloadsDir..." -ForegroundColor Cyan
$zip = Get-ChildItem -Path $DownloadsDir -Filter $ZipPattern |
       Sort-Object LastWriteTime -Descending |
       Select-Object -First 1

if (-not $zip) {
    Write-Host "No tol_update zip found in $DownloadsDir." -ForegroundColor Red
    Write-Host "Make sure the zip is downloaded there, then re-run."
    exit 1
}

Write-Host "Found: $($zip.Name) (modified $($zip.LastWriteTime))" -ForegroundColor Green

# --- 2. Extract to a temp folder -------------------------------------
$temp = Join-Path $env:TEMP "tol_deploy_$(Get-Random)"
Write-Host "Extracting to $temp..."
Expand-Archive -Path $zip.FullName -DestinationPath $temp -Force

# Sanity-check: zip should contain a top-level src/ folder
$zipSrc = Join-Path $temp "src"
if (-not (Test-Path $zipSrc)) {
    Write-Host "ERROR: zip doesn't contain a top-level src/ folder." -ForegroundColor Red
    Write-Host "Contents found:"
    Get-ChildItem $temp
    exit 1
}

# --- 3. Copy into project, overwriting -------------------------------
$projSrc = Join-Path $ProjectRoot "src"
Write-Host "Copying files into $projSrc..."

# robocopy: /E include empty dirs, /NP no progress, /NFL /NDL quiet
robocopy $zipSrc $projSrc /E /NP /NFL /NDL | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Host "ERROR: robocopy failed with code $LASTEXITCODE" -ForegroundColor Red
    exit 1
}

# --- 4. Cleanup temp -------------------------------------------------
Remove-Item -Recurse -Force $temp

# --- 5. Show what changed --------------------------------------------
Write-Host ""
Write-Host "Deployment complete. Changes in repo:" -ForegroundColor Green
Push-Location $ProjectRoot
git status --short
Pop-Location

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Check Studio - Rojo should have auto-synced the new files"
Write-Host "  2. Press F5 to test"
Write-Host "  3. If it works, commit and push your changes"