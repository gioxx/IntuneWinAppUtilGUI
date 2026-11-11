# IWAPG-Hlp-IntuneGraph.ps1
# Microsoft Graph access for the Publish to Intune window: sign-in, app search and content upload.

$script:IwaGraphAppsUri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps'
$script:IwaGraphScope = 'DeviceManagementApps.ReadWrite.All'
# Public client id of Microsoft's "Microsoft Graph Command Line Tools", used by Connect-MgGraph when no -ClientId is given.
$script:IwaGraphCliClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

function Test-IwaGraphModule {
    [bool](Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')
}

function Install-IwaGraphModule {
    Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}

function Test-IwaConnectionSetting {
    <#
    .SYNOPSIS
    Checks a custom app registration: returns an error message, or nothing when the values can be used.
    Both empty means Microsoft's own app.
    #>
    [CmdletBinding()]
    param([string]$ClientId, [string]$TenantId)

    $ClientId = "$ClientId".Trim(); $TenantId = "$TenantId".Trim()
    if (-not $ClientId -and -not $TenantId) { return }
    if (-not $ClientId -or -not $TenantId) { return 'Fill in both Client ID and Tenant ID, or leave both empty to use Microsoft''s app.' }
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($ClientId, [ref]$guid)) { return 'The Client ID is the app registration''s Application (client) ID, a GUID like 00000000-0000-0000-0000-000000000000.' }
    if (-not [guid]::TryParse($TenantId, [ref]$guid) -and $TenantId -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') {
        return 'The Tenant ID is the Directory (tenant) ID, a GUID, or the tenant domain like contoso.onmicrosoft.com.'
    }
}

function ConvertTo-IwaConnectionSetting {
    <#
    .SYNOPSIS
    Returns valid connection settings in canonical form (plain lower-case GUIDs, trimmed domain).
    #>
    [CmdletBinding()]
    param([string]$ClientId, [string]$TenantId)

    $clientId = "$ClientId".Trim(); $tenantId = "$TenantId".Trim()
    $guid = [guid]::Empty
    if ([guid]::TryParse($clientId, [ref]$guid)) { $clientId = $guid.ToString() }
    if ([guid]::TryParse($tenantId, [ref]$guid)) { $tenantId = $guid.ToString() }
    [pscustomobject]@{ ClientId = $clientId; TenantId = $tenantId }
}

function Get-IwaIntuneAccount {
    <#
    .SYNOPSIS
    Returns the signed-in account if the current Graph session has the Intune apps scope and uses the
    expected app: -ClientId (a custom app registration), or Microsoft's app when it is empty.
    #>
    [CmdletBinding()]
    param([string]$ClientId, [string]$TenantId)

    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { return $null }
    $context = Get-MgContext
    if (-not $context -or -not ($context.Scopes -contains $script:IwaGraphScope)) { return $null }
    # A session opened with the other app does not count: the next sign-in must use the configured one.
    $expected = if ($ClientId) { $ClientId } else { $script:IwaGraphCliClientId }
    if ($context.ClientId -and [string]$context.ClientId -ne $expected) { return $null }
    # Same multi-tenant app in another tenant: not the configured connection either (only a tenant GUID can be compared).
    $guid = [guid]::Empty
    if ($ClientId -and [guid]::TryParse($TenantId, [ref]$guid) -and $context.TenantId -and [string]$context.TenantId -ne $guid.ToString()) { return $null }
    [string]$context.Account
}

function Connect-IwaIntune {
    [CmdletBinding()]
    param([string]$ClientId, [string]$TenantId)

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $connect = @{ Scopes = $script:IwaGraphScope; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($ClientId) { $connect.ClientId = $ClientId; $connect.TenantId = $TenantId }
    Connect-MgGraph @connect
    Get-IwaIntuneAccount -ClientId $ClientId -TenantId $TenantId
}

function Get-IwaSignInErrorMessage {
    <#
    .SYNOPSIS
    Turns a sign-in failure into what to do about it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [switch]$CustomApp)

    $app = if ($CustomApp) { 'your app registration' } else { '"Microsoft Graph Command Line Tools"' }
    if ($Message -match 'AADSTS700016') { return 'The app registration was not found in that tenant. Check the Client ID and the Tenant ID in Connection settings.' }
    if ($Message -match 'AADSTS7000218') { return 'The app registration does not allow public client flows. In Entra ID, open it, then Authentication, and set "Allow public client flows" to Yes.' }
    # Windows signs in through the account broker (WAM), which uses its own redirect URI; http://localhost is the browser fallback.
    if ($Message -match 'AADSTS50011') { return 'A redirect URI is missing. In Entra ID, open the app registration, then Authentication, "Mobile and desktop applications", and add both ms-appx-web://Microsoft.AAD.BrokerPlugin/<Client ID> and http://localhost.' }
    if ($Message -match 'AADSTS65001|AADSTS90094|consent') { return "Admin consent is needed for DeviceManagementApps.ReadWrite.All on $app. Ask a tenant administrator to grant it, then sign in again." }
    if ($Message -match 'window handle') { return 'Sign-in could not open the Windows account prompt. Start the GUI from a PowerShell console window (Windows Terminal or the PowerShell console) and try again.' }
    "Sign-in failed: $Message"
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

function Test-IwaTransientHttpError {
    <#
    .SYNOPSIS
    True for failures worth retrying: no response (network), 408, 429 and 5xx. 400 or 403 fail the same way again.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $true }
    $status = [int]$response.StatusCode
    $status -eq 408 -or $status -eq 429 -or $status -ge 500
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
            if (-not (Test-IwaTransientHttpError -ErrorRecord $_)) { throw "Upload to Azure Storage failed: $($_.Exception.Message)" }
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
        [int]$PollIntervalSeconds = 2,
        [int]$ActivationAttempts = 7,
        [int]$ActivationRetrySeconds = 30
    )

    $appUri = "$script:IwaGraphAppsUri/$AppId"
    $lobUri = "$appUri/microsoft.graph.win32LobApp"
    $version = Invoke-IwaGraph -Method POST -Uri "$lobUri/contentVersions" -Body @{}
    $filesUri = "$lobUri/contentVersions/$($version.id)/files"
    $total = (Get-Item -LiteralPath $ContentFile).Length
    $file = Invoke-IwaGraph -Method POST -Uri $filesUri -Body ([ordered]@{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'
        name          = $Package.FileName
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
    # Intune can reject the activation for a few minutes after a large commit (Microsoft's sample waits 3 minutes), so retry.
    for ($attempt = 1; ; $attempt++) {
        try { Invoke-IwaGraph -Method PATCH -Uri $appUri -Body $patch | Out-Null; break }
        catch { if ($attempt -ge $ActivationAttempts) { throw }; Start-Sleep -Seconds $ActivationRetrySeconds }
    }
    [string]$version.id
}
