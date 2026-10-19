@{
    RootModule           = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion        = '1.1.3'
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
- Fixed: packaging could fail with exit code -2147024891 (0x80070005, access denied) when IntuneWinAppUtil ran in its own console window; the tool now runs without a window and its output is captured (the last lines are shown if it fails).
- Changed: packages are built in a local temporary folder and copied to the output folder only when complete, so sync clients (Dropbox, OneDrive) never see a partial file. The temporary working folder IntuneWinAppUtil leaves in %TEMP% is removed after a successful run.
- Added: a progress overlay shows the current packaging step and an estimated percentage; the window stays responsive while packaging, and closing it is blocked until the run ends. When the package is ready, an in-window panel shows its name and folder, with Open folder (Enter) and Close (Esc), and plays the Windows success sound.
- Improved: IntuneWinAppUtil errors now show the hexadecimal code and the Windows error text.
- Added: -Diag also writes a detailed log of every packaging run to %APPDATA%\IntuneWinAppUtilGUI\logs, including the tool output and, on failure, the files left behind and the processes holding them open.
'@
        }
    }
}
