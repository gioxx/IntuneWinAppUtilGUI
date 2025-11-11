@{
    RootModule           = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion        = '1.0.6'
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
- Bugfix: Delisted 1.0.4 from PowerShell Gallery and added again Show-IntuneWinAppUtilGUI to available commands.
- Bugfix: Removed any reference to ZIP uploads as setup files.
- Bugfix: Fixed PS 5.1 incompatibility in relative-path resolution ([System.IO.Path]::GetRelativePath is PS 7+).
- Bugfix: Final filename (of IntuneWin package) is proposed also if AppVersion is not specified in Invoke-AppDeployToolkit.ps1.
- Improved: Code cleanup, removed redundant GitHub download logic; refactoring.
- Improved: Validates setup file existence and type.
- Improved: Tries to create output folder when missing.
- Improved: Ensures exactly one ".intunewin" extension on output.
- Improved: If Source folder is not specified, it is inferred from Setup file.
- Improved: Added more inline comments for maintainability.
'@
        }
    }
}
