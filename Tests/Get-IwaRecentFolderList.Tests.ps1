Describe 'Get-IwaRecentFolderList' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-RecentFolders.ps1')
    }

    It 'puts the new folder first and keeps the others in order' {
        $result = Get-IwaRecentFolderList -Recent @('C:\A', 'C:\B') -Folder 'C:\C'
        $result | Should -Be @('C:\C', 'C:\A', 'C:\B')
    }

    It 'moves an existing folder to the top, ignoring case and a trailing backslash' {
        $result = Get-IwaRecentFolderList -Recent @('C:\A', 'c:\b\', 'C:\C') -Folder 'C:\B'
        $result | Should -Be @('C:\B', 'C:\A', 'C:\C')
    }

    It 'keeps at most Max entries' {
        $recent = 1..10 | ForEach-Object { "C:\Out$_" }
        $result = Get-IwaRecentFolderList -Recent $recent -Folder 'C:\New'
        $result.Count | Should -Be 10
        $result[0] | Should -Be 'C:\New'
        $result[-1] | Should -Be 'C:\Out9'
    }

    It 'drops blank entries and works without a new folder (config load)' {
        $result = Get-IwaRecentFolderList -Recent @('C:\A', '', $null, ' ', 'C:\A\')
        $result | Should -Be @('C:\A')
    }

    It 'returns an empty array when there is nothing to keep' {
        $result = Get-IwaRecentFolderList -Recent @()
        , $result | Should -BeOfType [string[]]
        $result.Count | Should -Be 0
    }
}
