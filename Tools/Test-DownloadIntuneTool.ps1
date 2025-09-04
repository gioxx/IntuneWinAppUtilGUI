<#
.SYNOPSIS
    Downloads and installs the latest version of IntuneWinAppUtil.exe from the official GitHub repository.
.DESCRIPTION
    This script downloads the latest master branch ZIP of the Microsoft-Win32-Content-Prep-Tool from GitHub,
    extracts the IntuneWinAppUtil.exe executable, and copies it to a local folder under %APPDATA%.
    It also cleans up temporary files created during the process.
.EXAMPLE
    .\Test-DownloadIntuneTool.ps1
.NOTES
    Requires PowerShell 5.1 or later.
    Needs internet access to download ZIP files and write permissions to %APPDATA%

    Author: Giovanni Solone
    Date: 2025-06-20
    License: MIT

    Modifications history:
    - 2025-06-20: Initial version.
#>

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-ErrorMsg($msg) { Write-Host "[ERR]  $msg" -ForegroundColor Red }

try {
    $url = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip"
    $zipName = "IntuneWinAppUtil-master.zip"
    $zipPath = Join-Path $env:TEMP $zipName
    $extractPath = Join-Path $env:TEMP "IntuneExtract"
    $finalDir = Join-Path $env:APPDATA "IntuneWinAppUtilGUI\bin"
    $exePath = Join-Path $finalDir "IntuneWinAppUtil.exe"

    Write-Info "Downloading latest master ZIP from GitHub..."
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    Write-Success "Downloaded to $zipPath"

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path $extractPath) {
        Write-Info "Cleaning previous extraction folder"
        Remove-Item $extractPath -Recurse -Force
    }

    Write-Info "Extracting ZIP to: $extractPath"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath, $true)

    Write-Info "Searching for IntuneWinAppUtil.exe..."
    $exeSource = Get-ChildItem -Path $extractPath -Recurse -Filter "IntuneWinAppUtil.exe" | Select-Object -First 1

    if (-not $exeSource) {
        Write-ErrorMsg "IntuneWinAppUtil.exe not found in extracted content."
        exit 1
    }

    Write-Success "Found executable: $($exeSource.FullName)"

    if (-not (Test-Path $finalDir)) {
        New-Item -ItemType Directory -Path $finalDir -Force | Out-Null
        Write-Info "Created destination: $finalDir"
    }

    Copy-Item -Path $exeSource.FullName -Destination $exePath -Force
    Write-Success "Copied to: $exePath"

    if (Test-Path $exePath) {
        Write-Info "Cleaning up temporary files..."
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        if (Test-Path $finalDir) { Remove-Item $finalDir -Recurse -Force }
        Write-Success "Cleanup complete."
    }

} catch {
    Write-ErrorMsg "Exception: $($_.Exception.Message)"
}
