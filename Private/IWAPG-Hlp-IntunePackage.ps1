# IWAPG-Hlp-IntunePackage.ps1
# Reads a .intunewin package (a zip with Metadata/Detection.xml and the encrypted Contents file).

function Read-IwaIntuneWinPackage {
    <#
    .SYNOPSIS
    Reads the metadata Intune needs from a .intunewin package, without extracting it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Package not found: $Path" }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    } catch {
        throw "'$Path' is not a valid .intunewin package: $($_.Exception.Message)"
    }
    try {
        $detection = $zip.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Metadata/Detection.xml' } | Select-Object -First 1
        $content = $zip.Entries | Where-Object { $_.FullName -like 'IntuneWinPackage/Contents/*' -and $_.Name } | Select-Object -First 1
        if (-not $detection -or -not $content) {
            throw "'$Path' is not a valid .intunewin package: Detection.xml or the encrypted content is missing."
        }
        $reader = New-Object System.IO.StreamReader($detection.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $info = $xml.ApplicationInfo
        $enc = $info.EncryptionInfo

        $msi = $null
        if ($info.MsiInfo -and $info.MsiInfo.MsiProductCode) {
            $msi = [pscustomobject]@{
                ProductCode      = [string]$info.MsiInfo.MsiProductCode
                ProductVersion   = [string]$info.MsiInfo.MsiProductVersion
                UpgradeCode      = [string]$info.MsiInfo.MsiUpgradeCode
                Publisher        = [string]$info.MsiInfo.MsiPublisher
                RequiresReboot   = ([string]$info.MsiInfo.MsiRequiresReboot -eq 'true')
                ExecutionContext = [string]$info.MsiInfo.MsiExecutionContext
            }
        }

        [pscustomobject]@{
            Path            = $Path
            Name            = [string]$info.Name
            SetupFile       = [string]$info.SetupFile
            ContentEntry    = $content.FullName
            UnencryptedSize = [int64]$info.UnencryptedContentSize
            EncryptedSize   = [int64]$content.Length
            EncryptionInfo  = [ordered]@{
                encryptionKey        = [string]$enc.EncryptionKey
                macKey               = [string]$enc.MacKey
                initializationVector = [string]$enc.InitializationVector
                mac                  = [string]$enc.Mac
                profileIdentifier    = [string]$enc.ProfileIdentifier
                fileDigest           = [string]$enc.FileDigest
                fileDigestAlgorithm  = [string]$enc.FileDigestAlgorithm
            }
            MsiInfo         = $msi
        }
    } finally {
        $zip.Dispose()
    }
}

function Expand-IwaIntuneWinContent {
    <#
    .SYNOPSIS
    Extracts the encrypted content file (the part uploaded to Intune) and returns its path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $target = Join-Path $Destination (Split-Path $Package.ContentEntry -Leaf)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Package.Path)
    try {
        $entry = $zip.GetEntry($Package.ContentEntry)
        if (-not $entry) { throw "Encrypted content '$($Package.ContentEntry)' not found in '$($Package.Path)'." }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    } finally {
        $zip.Dispose()
    }
    $target
}
