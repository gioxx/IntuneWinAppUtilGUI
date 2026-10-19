Describe 'Get-IntuneWinAppUtilWorkFolder' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    It 'returns the GUID work folder under the given temp folder' {
        $output = @"
INFO   Validating parameters
INFO   Compressing the source folder 'C:\Packages\Contoso Agent' to 'C:\Users\alice\AppData\Local\Temp\19197269-d398-424c-ba18-538a4d51e577\IntuneWinPackage\Contents\IntunePackage.intunewin'
INFO   Done!!!
"@
        Get-IntuneWinAppUtilWorkFolder -ToolOutput $output -TempPath 'C:\Users\ALICE~1\AppData\Local\Temp\' |
            Should -Be 'C:\Users\ALICE~1\AppData\Local\Temp\19197269-d398-424c-ba18-538a4d51e577'
    }

    It 'is not confused by apostrophes in the source path' {
        $output = "INFO   Compressing the source folder 'C:\Clients\O'Brien' to 'C:\Temp\0f8fad5b-d9cb-469f-a165-70867728950e\IntuneWinPackage\Contents\IntunePackage.intunewin'"
        Get-IntuneWinAppUtilWorkFolder -ToolOutput $output -TempPath 'C:\Temp' | Should -Be 'C:\Temp\0f8fad5b-d9cb-469f-a165-70867728950e'
    }

    It 'takes the destination GUID even when the source path contains a look-alike segment' {
        $output = "INFO   Compressing the source folder 'C:\Temp\11111111-2222-3333-4444-555555555555\IntuneWinPackage\Contents\IntunePackage.intunewin' to 'C:\Temp\0f8fad5b-d9cb-469f-a165-70867728950e\IntuneWinPackage\Contents\IntunePackage.intunewin'"
        Get-IntuneWinAppUtilWorkFolder -ToolOutput $output -TempPath 'C:\Temp' | Should -Be 'C:\Temp\0f8fad5b-d9cb-469f-a165-70867728950e'
    }

    It 'returns nothing when the folder name is not a GUID' {
        $output = "INFO   Compressing the source folder 'C:\Src' to 'C:\Temp\work\IntuneWinPackage\Contents\IntunePackage.intunewin'"
        Get-IntuneWinAppUtilWorkFolder -ToolOutput $output | Should -BeNullOrEmpty
    }

    It 'returns nothing when the output has no compression line' {
        Get-IntuneWinAppUtilWorkFolder -ToolOutput '' | Should -BeNullOrEmpty
        Get-IntuneWinAppUtilWorkFolder -ToolOutput 'INFO   Done!!!' | Should -BeNullOrEmpty
    }
}
