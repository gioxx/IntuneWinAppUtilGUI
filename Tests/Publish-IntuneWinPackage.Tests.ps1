Describe 'Publish-IntuneWinPackage' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    BeforeEach {
        $staging = Join-Path $TestDrive ("staging-{0}" -f ([guid]::NewGuid()))
        $output  = Join-Path $TestDrive ("output-{0}" -f ([guid]::NewGuid()))
        New-Item -ItemType Directory -Path $staging, $output | Out-Null
        $package = Join-Path $staging 'Setup.intunewin'
        Set-Content -Path $package -Value 'package'
    }

    It 'copies under a temporary name, renames, then removes the staged file' {
        $dest = Join-Path $output 'App_1.0.intunewin'
        Publish-IntuneWinPackage -Path $package -Destination $dest -CopyFirst

        Get-Content $dest | Should -Be 'package'
        Test-Path "$dest.partial" | Should -BeFalse
        Test-Path $package | Should -BeFalse
    }

    It 'moves the file when CopyFirst is not set' {
        $dest = Join-Path $staging 'App_1.0.intunewin'
        Publish-IntuneWinPackage -Path $package -Destination $dest

        Get-Content $dest | Should -Be 'package'
        Test-Path $package | Should -BeFalse
    }

    It 'throws, keeps the staged file and leaves no partial file when the copy fails' {
        $dest = Join-Path $output 'missing-folder\App_1.0.intunewin'
        { Publish-IntuneWinPackage -Path $package -Destination $dest -CopyFirst -MaxAttempts 1 } | Should -Throw

        Test-Path $package | Should -BeTrue
        Test-Path "$dest.partial" | Should -BeFalse
    }

    It 'throws and keeps the staged file when the destination already exists' {
        $dest = Join-Path $output 'App_1.0.intunewin'
        Set-Content -Path $dest -Value 'existing'
        { Publish-IntuneWinPackage -Path $package -Destination $dest -CopyFirst -MaxAttempts 2 } | Should -Throw

        Get-Content $dest | Should -Be 'existing'
        Test-Path $package | Should -BeTrue
        Test-Path "$dest.partial" | Should -BeFalse
    }
}
