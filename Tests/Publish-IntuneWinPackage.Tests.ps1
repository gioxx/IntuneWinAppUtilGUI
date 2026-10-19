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
        Get-ChildItem $output -Recurse -Filter '*.partial' | Should -BeNullOrEmpty
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
        Get-ChildItem $output -Recurse -Filter '*.partial' | Should -BeNullOrEmpty
    }

    It 'publishes under the next free suffix when the destination already exists' {
        $dest = Join-Path $output 'App_1.0.intunewin'
        Set-Content -Path $dest -Value 'existing'
        Set-Content -Path (Join-Path $output 'App_1.0_1.intunewin') -Value 'existing too'

        $published = Publish-IntuneWinPackage -Path $package -Destination $dest -CopyFirst

        $published | Should -Be (Join-Path $output 'App_1.0_2.intunewin')
        Get-Content $published | Should -Be 'package'
        Get-Content $dest | Should -Be 'existing'
        Test-Path $package | Should -BeFalse
        Get-ChildItem $output -Recurse -Filter '*.partial' | Should -BeNullOrEmpty
    }

    It 'publishes a final name close to the 255-character limit' {
        $dest = Join-Path $output (('a' * 240) + '.intunewin')
        Publish-IntuneWinPackage -Path $package -Destination $dest -CopyFirst -MaxAttempts 1 | Should -Be $dest
        Get-Content -LiteralPath $dest | Should -Be 'package'
    }

    It 'returns the published path' {
        $dest = Join-Path $output 'App_1.0.intunewin'
        Publish-IntuneWinPackage -Path $package -Destination $dest -CopyFirst | Should -Be $dest
    }
}
