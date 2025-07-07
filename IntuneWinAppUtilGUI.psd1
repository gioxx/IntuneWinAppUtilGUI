@{
    RootModule         = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion      = '1.0.2'
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
            Tags         = @('Intune', 'Win32', 'GUI', 'packaging', 'IntuneWinAppUtil', 'IntuneWinAppUtil.exe', 'Microsoft', 'PowerShell')
            License      = 'MIT'
            ProjectUri   = 'https://github.com/gioxx/IntuneWinAppUtilGUI'
            Icon         = 'icon.png'
            Readme       = 'README.md'
            ReleaseNotes = @'
            - Fixed: Rename-Item -Path $defaultPath -NewName $newName -Force when the file already exists. Now I rename the file using an incremental _$counter (starting from 1).
            - Fixed: Get-ChildItem: Cannot find path IntuneWinAppUtilGUI\1.0.0\Private because it does not exist.
'@
        }
    }
}