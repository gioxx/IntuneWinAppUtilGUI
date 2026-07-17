Describe 'Get-IntuneFileVersion' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Public\Get-IntuneFileVersion.ps1')
    }

    It 'returns the FileVersion for an executable' {
        $path = Join-Path $PSHOME 'pwsh.exe'
        Get-IntuneFileVersion -Path $path | Should -Be ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion)
    }

    It 'throws when the path does not exist' {
        $missingPath = Join-Path $env:TEMP ("missing-{0}.exe" -f ([guid]::NewGuid()))
        $threw = $false
        try {
            Get-IntuneFileVersion -Path $missingPath -ErrorAction Stop | Out-Null
        } catch {
            $threw = $true
        }
        $threw | Should -Be $true
    }

    It 'throws when the path is a directory' {
        $threw = $false
        try {
            Get-IntuneFileVersion -Path $TestDrive -ErrorAction Stop | Out-Null
        } catch {
            $threw = $true
        }
        $threw | Should -Be $true
    }
}
