Describe 'Get-SetupSuggestion' {
    BeforeAll {
        # Set-SetupFromSource (defined in the same file) types a parameter as
        # [System.Windows.Controls.TextBox], so PresentationFramework must be
        # loaded before dot-sourcing, same as the background scan job does.
        Add-Type -AssemblyName PresentationFramework
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Setup.ps1')
    }

    It 'returns $null when SourcePath does not exist' {
        $missing = Join-Path $TestDrive ("missing-{0}" -f ([guid]::NewGuid()))
        Get-SetupSuggestion -SourcePath $missing | Should -BeNullOrEmpty
    }

    It 'returns $null when CurrentSetupFile already points to an existing absolute file' {
        $source = Join-Path $TestDrive 'AlreadySet'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        $existing = Join-Path $source 'install.exe'
        New-Item -Path $existing -ItemType File -Force | Out-Null

        Get-SetupSuggestion -SourcePath $source -CurrentSetupFile $existing | Should -BeNullOrEmpty
    }

    It 'returns $null when CurrentSetupFile already points to an existing file relative to SourcePath' {
        $source = Join-Path $TestDrive 'AlreadySetRelative'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'install.ps1') -ItemType File -Force | Out-Null

        Get-SetupSuggestion -SourcePath $source -CurrentSetupFile 'install.ps1' | Should -BeNullOrEmpty
    }

    It 'returns $null when no EXE/MSI is found under SourcePath' {
        $source = Join-Path $TestDrive 'Empty'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'readme.txt') -ItemType File -Force | Out-Null

        Get-SetupSuggestion -SourcePath $source | Should -BeNullOrEmpty
    }

    It 'detects Invoke-AppDeployToolkit.exe and returns its relative path' {
        $source = Join-Path $TestDrive 'PSADT'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'Invoke-AppDeployToolkit.exe') -ItemType File -Force | Out-Null

        $result = Get-SetupSuggestion -SourcePath $source
        $result | Should -Not -BeNullOrEmpty
        $result.SetupFile | Should -Be 'Invoke-AppDeployToolkit.exe'
    }

    It 'extracts AppName and AppVersion from Invoke-AppDeployToolkit.ps1 for the final filename' {
        $source = Join-Path $TestDrive 'PSADTWithMetadata'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'Invoke-AppDeployToolkit.exe') -ItemType File -Force | Out-Null
        Set-Content -Path (Join-Path $source 'Invoke-AppDeployToolkit.ps1') -Value @'
$adtSession.AppName = 'Contoso App'
$adtSession.AppVersion = '1.2.3'
'@

        $result = Get-SetupSuggestion -SourcePath $source
        $result.SetupFile | Should -Be 'Invoke-AppDeployToolkit.exe'
        $result.FinalFilename | Should -Be 'ContosoApp_1.2.3'
    }

    It 'omits the version segment when AppVersion is missing' {
        $source = Join-Path $TestDrive 'PSADTNoVersion'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'Invoke-AppDeployToolkit.exe') -ItemType File -Force | Out-Null
        Set-Content -Path (Join-Path $source 'Invoke-AppDeployToolkit.ps1') -Value @'
$adtSession.AppName = 'Contoso App'
'@

        $result = Get-SetupSuggestion -SourcePath $source
        $result.FinalFilename | Should -Be 'ContosoApp'
    }

    It 'does not override an already-populated Final Filename' {
        $source = Join-Path $TestDrive 'PSADTKeepFinal'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'Invoke-AppDeployToolkit.exe') -ItemType File -Force | Out-Null
        Set-Content -Path (Join-Path $source 'Invoke-AppDeployToolkit.ps1') -Value @'
$adtSession.AppName = 'Contoso App'
'@

        $result = Get-SetupSuggestion -SourcePath $source -CurrentFinalFilename 'KeepMe'
        $result.SetupFile | Should -Be 'Invoke-AppDeployToolkit.exe'
        $result.FinalFilename | Should -BeNullOrEmpty
    }

    It 'falls back to an MSI when no PSADT executable is present' {
        $source = Join-Path $TestDrive 'MsiOnly'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'app.msi') -ItemType File -Force | Out-Null

        # The MSI isn't a real installer database, so Get-MsiPackageMetadata fails and
        # is swallowed; the setup file is still suggested, just without a final filename.
        $result = Get-SetupSuggestion -SourcePath $source
        $result | Should -Not -BeNullOrEmpty
        $result.SetupFile | Should -Be 'app.msi'
        $result.FinalFilename | Should -BeNullOrEmpty
    }

    It 'prefers Invoke-AppDeployToolkit.exe over a sibling MSI' {
        $source = Join-Path $TestDrive 'ExeOverMsi'
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $source 'Invoke-AppDeployToolkit.exe') -ItemType File -Force | Out-Null
        New-Item -Path (Join-Path $source 'app.msi') -ItemType File -Force | Out-Null

        $result = Get-SetupSuggestion -SourcePath $source
        $result.SetupFile | Should -Be 'Invoke-AppDeployToolkit.exe'
    }
}
