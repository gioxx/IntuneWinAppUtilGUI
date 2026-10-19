Describe 'IntuneWinAppUtilGUI module' {
    BeforeAll {
        $manifestPath = Join-Path $PSScriptRoot '..\IntuneWinAppUtilGUI.psd1'
        $module = Import-Module $manifestPath -Force -PassThru
    }

    It 'has a valid manifest and exports the file version helper' {
        $module.Version.ToString() | Should -Be '1.1.3'
        @($module.ExportedFunctions.Keys) | Should -Contain 'Get-IntuneFileVersion'
    }

    It 'imports the file version helper' {
        (Get-Command Get-IntuneFileVersion -ErrorAction Stop).Source | Should -Be 'IntuneWinAppUtilGUI'
    }

    # The manifest declares PowerShell 5.1 support, so PowerShell 7-only syntax must not slip in.
    It 'imports in Windows PowerShell 5.1' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        # A parse error in a dot-sourced helper is reported without stopping the import, so check $Error too.
        $output = & powershell.exe -NoProfile -NonInteractive -Command "Import-Module '$manifestPath' -ErrorAction Stop; if (`$Error.Count) { `$Error | ForEach-Object { `$_.ToString() }; exit 1 }; (Get-Command -Module IntuneWinAppUtilGUI).Count" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        [int]($output | Select-Object -Last 1) | Should -Be 2
    }
}
