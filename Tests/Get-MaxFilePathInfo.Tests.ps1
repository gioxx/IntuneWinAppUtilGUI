Describe 'Get-MaxFilePathInfo' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework   # Update-PathLengthIndicator types a WPF parameter
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-PathLength.ps1')
    }

    It 'returns the longest path and the total size in one pass, reporting progress' {
        $root = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Path (Join-Path $root 'deeper\folder') -Force | Out-Null
        Set-Content -Path (Join-Path $root 'a.txt') -Value ('x' * 10) -NoNewline
        $long = Join-Path $root 'deeper\folder\longer-name.bin'
        [System.IO.File]::WriteAllBytes($long, (New-Object byte[] 90))
        1..399 | ForEach-Object { [System.IO.File]::WriteAllBytes((Join-Path $root "f$_.bin"), [byte[]]@(1)) }

        $calls = 0
        $info = Get-MaxFilePathInfo -RootPath $root -OnProgress { $script:calls++ }

        $info.Path | Should -Be $long
        $info.Length | Should -Be $long.Length
        $info.TotalBytes | Should -Be (10 + 90 + 399)
        $script:calls | Should -Be 2   # 401 files, one call every 200
    }
}
