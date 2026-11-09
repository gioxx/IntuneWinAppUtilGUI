@{
    RootModule           = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion        = '1.1.4'
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
- Added: the package result panel has a Copy path button that copies the full path of the .intunewin file to the clipboard.
- Added: the Output Folder field remembers the last 10 folders used for a successful package; pick one from the drop-down or remove them all with Clear recent. The list is stored in config.json.
'@
        }
    }
}
