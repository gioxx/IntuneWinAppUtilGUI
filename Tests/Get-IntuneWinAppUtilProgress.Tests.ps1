Describe 'Get-IntuneWinAppUtilProgress' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    It 'starts at 2% before the tool writes anything' {
        $p = Get-IntuneWinAppUtilProgress -ToolOutput ''
        $p.Percent | Should -Be 2
        $p.Step | Should -Be 'Starting IntuneWinAppUtil'
    }

    It 'advances the source compression with the size of the archive being written' {
        $work = Join-Path $TestDrive 'work\IntuneWinPackage\Contents'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $work 'IntunePackage.intunewin'
        [System.IO.File]::WriteAllBytes($zip, (New-Object byte[] 500))
        $output = @"
INFO   Validating parameters
INFO   Compressing the source folder 'C:\Src' to '$zip'
INFO   Calculated size for folder 'C:\Src' is 1000 within 5 milliseconds
"@
        $p = Get-IntuneWinAppUtilProgress -ToolOutput $output
        $p.Step | Should -Be 'Compressing the source folder'
        $p.Percent | Should -Be (5 + [int](65 * 0.5))
    }

    It 'maps the later fixed steps in increasing order' {
        $steps = @(
            "INFO   Encrypting file 'C:\x\IntunePackage.intunewin'",
            "INFO   Computing SHA256 hash for C:\x\abc",
            "INFO   Generating detection XML file 'C:\x\Detection.xml'",
            "INFO   Removing temporary files",
            "INFO   Done!!!"
        )
        $percents = foreach ($line in $steps) { (Get-IntuneWinAppUtilProgress -ToolOutput $line).Percent }
        $percents | Should -Be @(72, 78, 82, 94, 95)
    }

    It 'never exceeds the package-building range when the archive is larger than expected' {
        $out = Join-Path $TestDrive 'Setup.intunewin'
        [System.IO.File]::WriteAllBytes($out, (New-Object byte[] 5000))
        $output = @"
INFO   Compressing folder 'C:\x\IntuneWinPackage' to '$out'
INFO   Calculated size for folder 'C:\x\IntuneWinPackage' is 1000 within 1 milliseconds
"@
        (Get-IntuneWinAppUtilProgress -ToolOutput $output).Percent | Should -Be 93
    }
}

Describe 'Read-SharedTextFile' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-Tool.ps1')
    }

    It 'reads a file another handle is still writing' {
        $file = Join-Path $TestDrive 'out.txt'
        $writer = [System.IO.FileStream]::new($file, 'Create', 'Write', 'Read')
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("INFO   Validating parameters`r`n")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            Read-SharedTextFile -Path $file | Should -Match 'Validating parameters'
        } finally {
            $writer.Dispose()
        }
    }

    It 'returns an empty string for a missing file' {
        Read-SharedTextFile -Path (Join-Path $TestDrive 'missing.txt') | Should -Be ''
    }
}
