# IWAPG-Hlp-IntuneGraph.ps1
# Microsoft Graph access for the Publish to Intune window: sign-in, app search and content upload.

$script:IwaGraphAppsUri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps'
$script:IwaGraphScope = 'DeviceManagementApps.ReadWrite.All'

function Test-IwaGraphModule {
    [bool](Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')
}

function Install-IwaGraphModule {
    Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}

function Get-IwaIntuneAccount {
    <#
    .SYNOPSIS
    Returns the signed-in account if the current Graph session has the Intune apps scope.
    #>
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { return $null }
    $context = Get-MgContext
    if ($context -and ($context.Scopes -contains $script:IwaGraphScope)) { [string]$context.Account } else { $null }
}

function Connect-IwaIntune {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -Scopes $script:IwaGraphScope -NoWelcome -ErrorAction Stop
    Get-IwaIntuneAccount
}

function Disconnect-IwaIntune {
    if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-IwaGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )

    $params = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ConvertTo-Json -InputObject $Body -Depth 10
        $params.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @params
}

function Get-IwaGraphErrorMessage {
    <#
    .SYNOPSIS
    Turns a Graph failure into "code: message" for the UI, without the stack trace.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    $texts = @([string]$ErrorRecord.ErrorDetails.Message, [string]$ErrorRecord.Exception.Message) | Where-Object { $_ }
    foreach ($text in $texts) {
        $start = $text.IndexOf('{')
        $end = $text.LastIndexOf('}')
        if ($start -lt 0 -or $end -le $start) { continue }
        try {
            $json = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop
            if ($json.error) { return '{0}: {1}' -f $json.error.code, $json.error.message }
        } catch { }
    }
    if ($texts) { @($texts)[0] } else { 'Unknown error.' }
}

function Get-IwaWin32App {
    <#
    .SYNOPSIS
    Lists Win32 apps whose name contains -Search, or reads one app with -Id.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Search')]
    param(
        [Parameter(ParameterSetName = 'Search')][string]$Search,
        [Parameter(Mandatory, ParameterSetName = 'Id')][string]$Id
    )

    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        return Invoke-IwaGraph -Method GET -Uri "$script:IwaGraphAppsUri/$Id"
    }
    # shortcut: filters by name on the client, since Graph does not combine isof() with contains(); fine up to a few thousand apps.
    $pattern = if ($Search) { '*' + [System.Management.Automation.WildcardPattern]::Escape($Search) + '*' } else { '*' }
    $uri = $script:IwaGraphAppsUri + "?`$filter=isof('microsoft.graph.win32LobApp')&`$select=id,displayName,publisher"
    $apps = New-Object System.Collections.Generic.List[object]
    while ($uri) {
        $page = Invoke-IwaGraph -Method GET -Uri $uri
        foreach ($app in @($page.value | Where-Object { $_ })) {
            if ([string]$app.displayName -like $pattern) { $apps.Add($app) }
        }
        $uri = $page.'@odata.nextLink'
    }
    $apps | Sort-Object displayName
}

function Get-IwaIntunePortalUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)
    "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppId"
}

function Invoke-IwaBlobRequest {
    <#
    .SYNOPSIS
    PUT to the Azure Storage SAS URI Intune hands out, retrying transient failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Body,
        [string]$ContentType,
        [hashtable]$Headers = @{},
        [int]$MaxAttempts = 3
    )

    # Windows PowerShell's progress bar slows Invoke-WebRequest down a lot.
    $ProgressPreference = 'SilentlyContinue'
    $params = @{ Method = 'Put'; Uri = $Uri; Body = $Body; Headers = $Headers; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($ContentType) { $params.ContentType = $ContentType }
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest @params | Out-Null
            return
        } catch {
            if ($attempt -ge $MaxAttempts) { throw "Upload to Azure Storage failed after $MaxAttempts attempts: $($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Wait-IwaContentFileState {
    <#
    .SYNOPSIS
    Polls a content file until uploadState is "<State>Success"; throws on "<State>Failed"/"<State>TimedOut".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$State,
        [int]$PollIntervalSeconds = 2,
        [int]$MaxAttempts = 90
    )

    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        $file = Invoke-IwaGraph -Method GET -Uri $Uri
        $current = [string]$file.uploadState
        if ($current -eq "${State}Success") { return $file }
        if ($current -eq "${State}Failed" -or $current -eq "${State}TimedOut") {
            throw "Intune reported '$current' for the package upload."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out waiting for Intune ($State)."
}

function Publish-IwaWin32AppContent {
    <#
    .SYNOPSIS
    Uploads the encrypted package content to a Win32 app and makes it the committed version.
    .DESCRIPTION
    The app keeps its previous content until the final PATCH, which runs only after a successful commit.
    Settings passed in -AppBody are applied together with the new content in that same PATCH.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$ContentFile,
        [scriptblock]$OnProgress,
        [System.Collections.IDictionary]$AppBody,
        [int]$ChunkSizeBytes = 6MB,
        [int]$SasRenewSeconds = 420,
        [int]$PollIntervalSeconds = 2
    )

    $appUri = "$script:IwaGraphAppsUri/$AppId"
    $lobUri = "$appUri/microsoft.graph.win32LobApp"
    $version = Invoke-IwaGraph -Method POST -Uri "$lobUri/contentVersions" -Body @{}
    $filesUri = "$lobUri/contentVersions/$($version.id)/files"
    $total = (Get-Item -LiteralPath $ContentFile).Length
    $file = Invoke-IwaGraph -Method POST -Uri $filesUri -Body ([ordered]@{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'
        name          = Split-Path $ContentFile -Leaf
        size          = $Package.UnencryptedSize
        sizeEncrypted = $total
        manifest      = $null
        isDependency  = $false
    })
    $fileUri = "$filesUri/$($file.id)"
    $sasUri = (Wait-IwaContentFileState -Uri $fileUri -State 'azureStorageUriRequest' -PollIntervalSeconds $PollIntervalSeconds).azureStorageUri
    $sasIssued = Get-Date

    $blockIds = New-Object System.Collections.Generic.List[string]
    $stream = [System.IO.File]::OpenRead($ContentFile)
    try {
        $buffer = New-Object byte[] $ChunkSizeBytes
        $sent = [int64]0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            # The SAS URI lasts about 10 minutes; renew it before it runs out.
            if (((Get-Date) - $sasIssued).TotalSeconds -ge $SasRenewSeconds) {
                Invoke-IwaGraph -Method POST -Uri "$fileUri/renewUpload" -Body @{} | Out-Null
                $sasUri = (Wait-IwaContentFileState -Uri $fileUri -State 'azureStorageUriRenewal' -PollIntervalSeconds $PollIntervalSeconds).azureStorageUri
                $sasIssued = Get-Date
            }
            $chunk = $buffer
            if ($read -lt $buffer.Length) {
                $chunk = New-Object byte[] $read
                [Array]::Copy($buffer, $chunk, $read)
            }
            $blockId = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($blockIds.Count.ToString('0000')))
            Invoke-IwaBlobRequest -Uri "$sasUri&comp=block&blockid=$([uri]::EscapeDataString($blockId))" -Body $chunk -Headers @{ 'x-ms-blob-type' = 'BlockBlob' }
            $blockIds.Add($blockId)
            $sent += $read
            if ($OnProgress) { & $OnProgress $sent $total }
        }
    } finally {
        $stream.Dispose()
    }

    $blockList = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    Invoke-IwaBlobRequest -Uri "$sasUri&comp=blocklist" -Body $blockList -ContentType 'application/xml'
    Invoke-IwaGraph -Method POST -Uri "$fileUri/commit" -Body @{ fileEncryptionInfo = $Package.EncryptionInfo } | Out-Null
    Wait-IwaContentFileState -Uri $fileUri -State 'commitFile' -PollIntervalSeconds $PollIntervalSeconds -MaxAttempts 600 | Out-Null
    $patch = [ordered]@{}
    if ($AppBody) { foreach ($key in $AppBody.Keys) { $patch[$key] = $AppBody[$key] } }
    $patch['@odata.type'] = '#microsoft.graph.win32LobApp'
    $patch['committedContentVersion'] = $version.id
    Invoke-IwaGraph -Method PATCH -Uri $appUri -Body $patch | Out-Null
    [string]$version.id
}
