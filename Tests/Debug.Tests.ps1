Describe 'Diagnostic log helpers' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Debug.ps1')
    }

    AfterEach {
        $script:IwaDebugLogPath = $null
    }

    It 'does not write anything when debug logging is disabled' {
        $script:IwaDebugLogPath = $null
        { Write-IwaDebugLog 'ignored' } | Should -Not -Throw
    }

    It 'appends timestamped lines and indents multi-line messages' {
        $script:IwaDebugLogPath = Join-Path $TestDrive 'diag.log'
        Write-IwaDebugLog "first`nsecond"

        $lines = Get-Content $script:IwaDebugLogPath
        $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}  first$'
        $lines[1] | Should -Match '^\s{26}second$'
    }

    It 'reports the current process as holder of a file it keeps open' {
        $file = Join-Path $TestDrive 'locked.bin'
        Set-Content -Path $file -Value 'x'
        $fs = [System.IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
        try {
            Get-FileLockingProcess -Path $file | Should -Contain "$((Get-Process -Id $PID).ProcessName) ($PID)"
        } finally {
            $fs.Dispose()
        }
    }

    It 'returns nothing for a file nobody holds' {
        $file = Join-Path $TestDrive 'free.bin'
        Set-Content -Path $file -Value 'x'
        Get-FileLockingProcess -Path $file | Should -BeNullOrEmpty
    }

    It 'logs the files of an inspected folder with their lock state' {
        $script:IwaDebugLogPath = Join-Path $TestDrive 'state.log'
        $folder = Join-Path $TestDrive 'staging'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file = Join-Path $folder 'IntunePackage.intunewin'
        Set-Content -Path $file -Value 'x'
        $fs = [System.IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
        try {
            Write-IwaDebugFileState -Since (Get-Date) -Folder $folder
        } finally {
            $fs.Dispose()
        }

        $log = Get-Content $script:IwaDebugLogPath -Raw
        $log | Should -Match ([regex]::Escape("Folder '$folder': 1 file(s)"))
        $log | Should -Match "IntunePackage\.intunewin .* held by: .*\($PID\)"
    }
}
