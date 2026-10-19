# IntuneWinAppUtilGUI.psm1

# Load UI-related assemblies once at module import time
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms

# Expose module root so public/private scripts can resolve resources
# (UI.xaml, Assets, etc.)
$script:ModuleRoot = $PSScriptRoot

# Private helpers
$privateDir = Join-Path $PSScriptRoot 'Private'
if (Test-Path $privateDir) {
    # foreach statement (not ForEach-Object): inside catch, $_ is the error, and a throw from a
    # pipeline script block is reported without stopping the import.
    foreach ($file in Get-ChildItem -Path $privateDir -Filter '*.ps1' -File) {
        try {
            . $file.FullName  # dot-source
        } catch {
            throw "Failed to load Private script '$($file.Name)': $($_.Exception.Message)"
        }
    }
}

# Public entry points
$publicDir = Join-Path $PSScriptRoot 'Public'
if (Test-Path $publicDir) {
    foreach ($file in Get-ChildItem -Path $publicDir -Filter '*.ps1' -File) {
        try {
            . $file.FullName  # dot-source
        } catch {
            throw "Failed to load Public script '$($file.Name)': $($_.Exception.Message)"
        }
    }
}