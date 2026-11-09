# IWAPG-Hlp-RecentFolders.ps1
# Most-recently-used list for the Output Folder field.
function Get-IwaRecentFolderList {
    # Returns $Folder first, then the other entries of $Recent without duplicates
    # (case-insensitive, trailing '\' ignored), keeping at most $Max entries.
    param(
        [string[]] $Recent,
        [string] $Folder,
        [int] $Max = 10
    )
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Folder) + @($Recent)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $key = $entry.Trim().TrimEnd('\')
        if (@($list | Where-Object { $_.TrimEnd('\') -eq $key }).Count) { continue }
        $list.Add($entry.Trim())
        if ($list.Count -ge $Max) { break }
    }
    , $list.ToArray()
}
