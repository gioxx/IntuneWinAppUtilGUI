Describe 'IntuneWinAppUtilGUI module' {
    BeforeAll {
        $manifestPath = Join-Path $PSScriptRoot '..\IntuneWinAppUtilGUI.psd1'
        $module = Import-Module $manifestPath -Force -PassThru
    }

    It 'has a valid manifest and exports the file version helper' {
        $module.Version.ToString() | Should -Be '1.0.9'
        @($module.ExportedFunctions.Keys) | Should -Contain 'Get-IntuneFileVersion'
    }

    It 'imports the file version helper' {
        (Get-Command Get-IntuneFileVersion -ErrorAction Stop).Source | Should -Be 'IntuneWinAppUtilGUI'
    }
}
