# IntuneWinAppUtilGUI.psm1

# Load UI-related assemblies once at module import time
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms

# Expose module root so public/private scripts can resolve resources (UI.xaml, Assets, etc.)
$script:ModuleRoot = $PSScriptRoot

# --- Load Private helpers first (NOT exported) ---
$privateDir = Join-Path $PSScriptRoot 'Private'
if (Test-Path $privateDir) {
    Get-ChildItem -Path $privateDir -Filter '*.ps1' -File | ForEach-Object {
        try {
            . $_.FullName  # dot-source
        } catch {
            throw "Failed to load Private script '$($_.Name)': $($_.Exception.Message)"
        }
    }
}

# --- Load Public entry points (will be exported) ---
$publicDir = Join-Path $PSScriptRoot 'Public'
if (Test-Path $publicDir) {
    Get-ChildItem -Path $publicDir -Filter '*.ps1' -File | ForEach-Object {
        try {
            . $_.FullName  # dot-source
        } catch {
            throw "Failed to load Public script '$($_.Name)': $($_.Exception.Message)"
        }
    }
}