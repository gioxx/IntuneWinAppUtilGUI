@{
    RootModule         = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion      = '1.0.3'
    GUID               = '7db79126-1b57-48d2-970a-4795692dfcfc'
    Author             = 'Giovanni Solone'
    Description        = 'GUI wrapper for IntuneWinAppUtil.exe with config file support and WPF interface.'

    PowerShellVersion  = '5.1'

    RequiredAssemblies = @(
        'System.Windows.Forms',
        'PresentationFramework'
    )

    FunctionsToExport  = @('Show-IntuneWinAppUtilGui')

    CmdletsToExport    = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData        = @{
        PSData = @{
            Tags         = @('Intune', 'Win32', 'GUI', 'packaging', 'IntuneWinAppUtil', 'IntuneWinAppUtil.exe', 'Microsoft', 'PowerShell', 'PSADT', 'AppDeployToolkit')
            License      = 'MIT'
            ProjectUri   = 'https://github.com/gioxx/IntuneWinAppUtilGUI'
            Icon         = 'icon.png'
            Readme       = 'README.md'
            ReleaseNotes = @'
            - NEW: PSADT - If Invoke-AppDeployToolkit.exe is detected in the source folder, it is proposed as the default setup file. If Invoke-AppDeployToolkit.ps1 is detected in the source folder, it is parsed to propose a name for the IntuneWin package.
            - Improved: The version of the IntuneWinAppUtil.exe file in use is shown on the screen. You can also use the "Force download" button to download the latest version available from GitHub. The list of versions is available at the "Version history" link.
'@
        }
    }
}
