Describe 'IntuneWinAppUtil update check' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    Context 'Test-IntuneWinAppUtilUpdateAvailable' {
        It 'reports an update when the latest FileVersion is newer' {
            Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion '6.2404.13.0' -LatestVersion '6.2509.50.0' | Should -BeTrue
        }
        It 'reports no update when the installed version is the latest or newer' {
            Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion '6.2509.50.0' -LatestVersion '6.2509.50.0' | Should -BeFalse
            Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion '6.2601.1.0' -LatestVersion '6.2509.50.0' | Should -BeFalse
        }
        It 'compares numerically, not as text' {
            Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion '6.2509.9.0' -LatestVersion '6.2509.50.0' | Should -BeTrue
        }
        It 'treats a missing or unreadable installed version as outdated' {
            Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion '' -LatestVersion '6.2509.50.0' | Should -BeTrue
            Test-IntuneWinAppUtilUpdateAvailable -InstalledVersion 'unknown' -LatestVersion '6.2509.50.0' | Should -BeTrue
        }
    }

    Context 'Get-IntuneWinAppUtilReleaseZipUrl' {
        It 'points to the ZIP of the advertised tag, not the master branch' {
            Get-IntuneWinAppUtilReleaseZipUrl -Release 'v1.8.7' | Should -Be 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/tags/v1.8.7.zip'
            Get-IntuneWinAppUtilReleaseZipUrl -Release '1.8.3' | Should -Be 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/tags/1.8.3.zip'
        }
    }

    Context 'Get-IntuneWinAppUtilLatestVersion' {
        It 'returns the latest release from the version list' {
            Mock Invoke-RestMethod { [pscustomobject]@{ latest = [pscustomobject]@{ release = 'v1.8.7'; fileVersion = '6.2509.50.0' } } }
            $latest = Get-IntuneWinAppUtilLatestVersion
            $latest.Release | Should -Be 'v1.8.7'
            $latest.FileVersion | Should -Be '6.2509.50.0'
        }
        It 'throws when the list has no valid latest version' {
            Mock Invoke-RestMethod { [pscustomobject]@{ latest = $null } }
            { Get-IntuneWinAppUtilLatestVersion } | Should -Throw '*no valid latest version*'
        }
        It 'throws when the latest version has no release tag' {
            Mock Invoke-RestMethod { [pscustomobject]@{ latest = [pscustomobject]@{ release = ' '; fileVersion = '6.2509.50.0' } } }
            { Get-IntuneWinAppUtilLatestVersion } | Should -Throw '*no release*'
        }
        It 'reads the JSON published in Tools' {
            $json = Join-Path $PSScriptRoot '..\Tools\IntuneWinAppUtilVersions.json'
            Mock Invoke-RestMethod { Get-Content -LiteralPath $json -Raw | ConvertFrom-Json }
            $latest = Get-IntuneWinAppUtilLatestVersion
            $latest.Release | Should -Match '^v?\d'
            { [version]$latest.FileVersion } | Should -Not -Throw
        }
    }
}
