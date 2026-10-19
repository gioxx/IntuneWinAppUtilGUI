Describe 'Get-IntuneWinAppUtilWorkFolder' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    It 'returns the GUID work folder from the tool output' {
        $output = @"
INFO   Validating parameters
INFO   Compressing the source folder 'C:\Packages\Contoso Agent' to 'C:\Users\alice\AppData\Local\Temp\19197269-d398-424c-ba18-538a4d51e577\IntuneWinPackage\Contents\IntunePackage.intunewin'
INFO   Done!!!
"@
        Get-IntuneWinAppUtilWorkFolder -ToolOutput $output | Should -Be 'C:\Users\alice\AppData\Local\Temp\19197269-d398-424c-ba18-538a4d51e577'
    }

    It 'returns nothing when the folder name is not a GUID' {
        $output = "INFO   Compressing the source folder 'C:\Src' to 'C:\Users\alice\AppData\Local\Temp\IntuneWinPackage\Contents\IntunePackage.intunewin'"
        Get-IntuneWinAppUtilWorkFolder -ToolOutput $output | Should -BeNullOrEmpty
    }

    It 'returns nothing when the output has no compression line' {
        Get-IntuneWinAppUtilWorkFolder -ToolOutput '' | Should -BeNullOrEmpty
        Get-IntuneWinAppUtilWorkFolder -ToolOutput 'INFO   Done!!!' | Should -BeNullOrEmpty
    }
}
