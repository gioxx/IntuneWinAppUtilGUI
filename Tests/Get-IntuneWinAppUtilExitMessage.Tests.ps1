Describe 'Get-IntuneWinAppUtilExitMessage' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    It 'shows the HRESULT, the Windows error text and the lock hint for access denied' {
        $msg = Get-IntuneWinAppUtilExitMessage -ExitCode -2147024891
        $msg | Should -Match '-2147024891 \(0x80070005\)'
        $msg | Should -Match ([regex]::Escape(([System.ComponentModel.Win32Exception]::new(5)).Message))
        $msg | Should -Match 'sync clients'
    }

    It 'adds the lock hint for a sharing violation' {
        Get-IntuneWinAppUtilExitMessage -ExitCode -2147024864 | Should -Match 'sync clients'
    }

    It 'adds the Windows error text without the lock hint for other Win32 errors' {
        # 0x80070002 = ERROR_FILE_NOT_FOUND
        $msg = Get-IntuneWinAppUtilExitMessage -ExitCode -2147024894
        $msg | Should -Match ([regex]::Escape(([System.ComponentModel.Win32Exception]::new(2)).Message))
        $msg | Should -Not -Match 'sync clients'
    }

    It 'shows only the code for non-Win32 exit codes' {
        Get-IntuneWinAppUtilExitMessage -ExitCode 1 | Should -Be 'IntuneWinAppUtil exited with code 1 (0x00000001).'
    }
}
