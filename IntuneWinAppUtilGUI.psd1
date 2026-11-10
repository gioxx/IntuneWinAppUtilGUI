@{
    RootModule           = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion        = '1.2.0'
    GUID                 = '7db79126-1b57-48d2-970a-4795692dfcfc'
    Author               = 'Giovanni Solone'
    Description          = 'GUI wrapper for IntuneWinAppUtil.exe with config file support and WPF interface.'

    # Minimum required PowerShell (PS 5.1 works; better with PS 7+)
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredAssemblies   = @()
    FunctionsToExport    = @('Show-IntuneWinAppUtilGUI', 'Get-IntuneFileVersion')
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
- Added: Publish to Intune (preview). Create a Win32 app in Intune, or update an existing one, from IntuneWinAppUtilGUI: app information, commands, requirements and detection rules (MSI, file/folder, registry, PowerShell script), then upload the package. Open it from Upload to Intune... after packaging, or from Publish to Intune... next to Run.
- Added: Publish to Intune signs in with Connect-MgGraph and installs Microsoft.Graph.Authentication for the current user when it is missing.
- Changed: the Run/Publish to Intune/Clear/Exit buttons are on two rows, and the Package created panel is wider.
'@
        }
    }
}
