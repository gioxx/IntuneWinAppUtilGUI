@{
    RootModule           = 'IntuneWinAppUtilGUI.psm1'
    ModuleVersion        = '2.0.0'
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
- Added: Publish to Intune (preview), a tab of the main window next to Package. Create a Win32 app in Intune, or update an existing one: app information, commands, requirements and detection rules (MSI, file/folder, registry, PowerShell script), then upload the package. Upload to Intune... in Package created opens the tab with the package just built; any .intunewin can be picked there too. Intune shows the package with the name chosen when packaging; Clear (on both tabs) and Start over empty both tabs for the next app.
- Added: sign-in through Microsoft Graph with your Microsoft account; Microsoft.Graph.Authentication is installed for the current user when it is missing. An app registration (your own Client ID and Tenant ID) can be used instead: an alpha feature, chosen from the arrow next to Sign in.
- Added: Check for updates of IntuneWinAppUtil.exe, against the version list kept in this repository; Version history links to the KB.
- Changed: Help, the update check, the tool download and the exit confirmation are in-window panels instead of message boxes.
- Changed: header tabs and a new header color; Ctrl+Tab switches tab, Enter packages only on the Package tab.
- Fixed: updating an app keeps the version of the package being uploaded, keeps "no architecture check" and keeps rules Intune returns without content; a failed create no longer leads to a second app; uploads retry only temporary errors.
'@
        }
    }
}
