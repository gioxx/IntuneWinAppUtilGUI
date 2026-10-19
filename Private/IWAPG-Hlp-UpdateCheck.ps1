function Get-PowerShellGalleryModuleVersion {
    <#
    .SYNOPSIS
    Returns the latest module version from PowerShell Gallery.
    .PARAMETER ModuleName
    The module name to query.
    .PARAMETER TimeoutSeconds
    Request timeout in seconds.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ModuleName,
        [Parameter()][int] $TimeoutSeconds = 10,
        [switch] $Detailed
    )

    try {
        $lastError = $null
        if (Get-Command -Name Find-Module -ErrorAction SilentlyContinue) {
            try {
                $galleryModule = Find-Module -Name $ModuleName -Repository PSGallery -ErrorAction Stop
                if ($galleryModule -and $galleryModule.Version) {
                    $latest = [version]$galleryModule.Version
                    if ($Detailed) { return [PSCustomObject]@{ Latest = $latest; Error = $null } } else { return $latest }
                }
            } catch {
                $lastError = $_.Exception.Message
                # fall back to OData endpoint below
            }
        }

        try {
            $tls12 = [Net.SecurityProtocolType]::Tls12
            [Net.ServicePointManager]::SecurityProtocol = $tls12 -bor [Net.ServicePointManager]::SecurityProtocol
        } catch { }

        # Windows PowerShell 5.1 does not load System.Net.Http by default
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

        $url = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$ModuleName'"
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        $resp = $client.GetAsync($url).Result
        if (-not $resp.IsSuccessStatusCode) {
            $lastError = "HTTP $($resp.StatusCode)"
            if ($Detailed) { return [PSCustomObject]@{ Latest = $null; Error = $lastError } } else { return $null }
        }

        $content = $resp.Content.ReadAsStringAsync().Result
        if (-not $content) {
            $lastError = "Empty response"
            if ($Detailed) { return [PSCustomObject]@{ Latest = $null; Error = $lastError } } else { return $null }
        }

        $xml = [xml]$content
        $versions = @()
        foreach ($entry in $xml.feed.entry) {
            $ver = $entry.properties.Version
            if ($ver) { $versions += [version]$ver }
        }
        if ($versions.Count -eq 0) {
            $lastError = "No versions found"
            if ($Detailed) { return [PSCustomObject]@{ Latest = $null; Error = $lastError } } else { return $null }
        }
        $latest = ($versions | Sort-Object -Descending | Select-Object -First 1)
        if ($Detailed) { return [PSCustomObject]@{ Latest = $latest; Error = $null } } else { return $latest }
    } catch {
        $msg = $_.Exception.Message
        if ($Detailed) { return [PSCustomObject]@{ Latest = $null; Error = $msg } } else { return $null }
    } finally {
        if ($client) { $client.Dispose() }
    }
}
