Describe 'Get-IntuneWinAppUtilTempFolder' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    It 'returns only GUID-named folders that contain IntuneWinPackage' {
        $temp = Join-Path $TestDrive 'temp'
        $toolFolder = Join-Path $temp ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $toolFolder 'IntuneWinPackage\Contents') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $temp ([guid]::NewGuid().ToString())) | Out-Null          # GUID, not the tool's
        New-Item -ItemType Directory -Path (Join-Path $temp 'other\IntuneWinPackage') -Force | Out-Null           # not a GUID name

        @(Get-IntuneWinAppUtilTempFolder -TempPath $temp) | Should -Be @($toolFolder)
    }

    It 'returns nothing when the folder does not exist' {
        Get-IntuneWinAppUtilTempFolder -TempPath (Join-Path $TestDrive 'missing') | Should -BeNullOrEmpty
    }
}
