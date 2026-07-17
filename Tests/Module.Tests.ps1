Describe 'IntuneWinAppUtilGUI module' {
    It 'has a valid manifest and exports the file version helper' {
        $manifest = Test-ModuleManifest -Path (Join-Path $PSScriptRoot '..\IntuneWinAppUtilGUI.psd1')
        $manifest.Version.ToString() | Should Be '1.0.9'
        (@($manifest.ExportedFunctions.Keys) -contains 'Get-IntuneFileVersion') | Should Be $true
    }

    It 'imports the file version helper' {
        Import-Module (Join-Path $PSScriptRoot '..\IntuneWinAppUtilGUI.psd1') -Force
        (Get-Command Get-IntuneFileVersion -ErrorAction Stop).Source | Should Be 'IntuneWinAppUtilGUI'
    }
}
