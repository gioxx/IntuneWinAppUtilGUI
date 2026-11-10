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
    $uri = $script:IwaGraphAppsUri + "?`$filter=isof('microsoft.graph.win32LobApp')&`$select=id,displayName,publisher,displayVersion"
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
