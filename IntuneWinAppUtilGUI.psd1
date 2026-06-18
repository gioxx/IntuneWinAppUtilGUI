@{
    RootModule           = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion        = '1.0.8'
    GUID                 = '7db79126-1b57-48d2-970a-4795692dfcfc'
    Author               = 'Giovanni Solone'
    Description          = 'GUI wrapper for IntuneWinAppUtil.exe with config file support and WPF interface.'

    # Minimum required PowerShell (PS 5.1 works; better with PS 7+)
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredAssemblies   = @()
    FunctionsToExport    = @('Show-IntuneWinAppUtilGUI')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('Intune', 'Win32', 'GUI', 'packaging', 'IntuneWinAppUtil', 'Microsoft', 'PowerShell', 'PSADT', 'AppDeployToolkit')
            ProjectUri   = 'https://github.com/gioxx/IntuneWinAppUtilGUI'
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            IconUri      = 'https://raw.githubusercontent.com/gioxx/IntuneWinAppUtilGUI/main/Assets/icon.png'
            ReleaseNotes = @'
- Fixed: Retries output rename when the target file is temporarily locked.
- Improved: Falls back to MSI metadata for PSADT/MSI-based packages when AppName/AppVersion are missing.
- Fixed: Replaced emoji UI glyphs with Windows-version-safe labels.
- Improved: Refreshed the main window layout with a cleaner, modern visual style.
- Improved: Added in-app Help for launch switches and keyboard shortcuts.
- Improved: Clarified confirmation popups for exit, download, path warnings and package completion.
- Fixed: ShowVersion and ForceUpdateBanner now provide immediate feedback in the refreshed header.
- Improved: Release naming and UI version now align with 1.0.8.
'@
        }
    }
}
