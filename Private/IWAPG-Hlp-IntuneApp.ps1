# IWAPG-Hlp-IntuneApp.ps1
# Win32 app model for the Publish to Intune window: form defaults, detection rules, Graph body, validation.

# Values accepted by win32LobApp.minimumSupportedWindowsRelease; the first is the default.
$script:IwaWindowsReleases = @('1607', '1703', '1709', '1803', '1809', '1903', '1909', '2004', '2H20', '21H1')

function Get-IwaWin32AppDefault {
    <#
    .SYNOPSIS
    Returns the form values for a new app built from a package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [string]$DisplayVersion
    )

    $setup = [string]$Package.SetupFile
    # For MSI packages Detection.xml holds the product name; for EXE it is only the setup file name.
    $name = if ($Package.MsiInfo) { [string]$Package.Name } else { [System.IO.Path]::GetFileNameWithoutExtension([string]$Package.Path) }
    $spec = [ordered]@{
        DisplayName           = $name
        Publisher             = ''
        DisplayVersion        = [string]$DisplayVersion
        Description           = $name
        InstallCommandLine    = "`"$setup`""
        UninstallCommandLine  = ''
        RunAsAccount          = 'system'
        DeviceRestartBehavior = 'basedOnReturnCode'
        MaxRunTimeInMinutes   = 60
        Architectures         = @('x64')
        MinimumWindowsRelease = $script:IwaWindowsReleases[0]
        Rules                 = @()
    }
    if ($Package.MsiInfo) {
        $msi = $Package.MsiInfo
        $spec.Publisher = [string]$msi.Publisher
        if ($msi.ProductVersion) { $spec.DisplayVersion = [string]$msi.ProductVersion }
        $spec.InstallCommandLine = "msiexec /i `"$setup`" /qn"
        $spec.UninstallCommandLine = "msiexec /x $($msi.ProductCode) /qn"
        $spec.Rules = @(@{ Type = 'MsiProductCode'; ProductCode = [string]$msi.ProductCode })
    }
    $spec
}

function New-IwaDetectionRule {
    <#
    .SYNOPSIS
    Builds a detection rule from the rule editor fields; throws a message meant for the user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('MsiProductCode', 'File', 'Registry', 'Script')][string]$Type,
        [string]$ProductCode,
        [string]$Path,
        [string]$FileOrFolderName,
        [string]$KeyPath,
        [string]$ValueName,
        [ValidateSet('exists', 'string', 'version')][string]$Operation = 'exists',
        [string]$Value,
        [switch]$Check32BitOn64System,
        [string]$ScriptContent,
        [switch]$RunAs32Bit,
        [switch]$EnforceSignatureCheck
    )

    $operator = switch ($Operation) { 'exists' { 'notConfigured' } 'string' { 'equal' } 'version' { 'greaterThanOrEqual' } }
    $compare = $null
    if ($Operation -ne 'exists') {
        if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Enter the value to compare.' }
        $compare = $Value.Trim()
    }

    switch ($Type) {
        'MsiProductCode' {
            if ($ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw 'Enter the MSI product code as {GUID}.' }
            @{ Type = 'MsiProductCode'; ProductCode = $ProductCode.ToUpperInvariant() }
        }
        'File' {
            if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($FileOrFolderName)) { throw 'Enter the folder path and the file or folder name.' }
            if ($Operation -eq 'string') { throw 'File rules can check "exists" or "version".' }
            @{ Type = 'File'; Path = $Path.Trim(); FileOrFolderName = $FileOrFolderName.Trim(); Operation = $Operation; Operator = $operator; Value = $compare; Check32BitOn64System = [bool]$Check32BitOn64System }
        }
        'Registry' {
            if ([string]::IsNullOrWhiteSpace($KeyPath)) { throw 'Enter the registry key path.' }
            if ($Operation -ne 'exists' -and [string]::IsNullOrWhiteSpace($ValueName)) { throw 'Enter the value name to compare.' }
            @{ Type = 'Registry'; KeyPath = $KeyPath.Trim(); ValueName = ([string]$ValueName).Trim(); Operation = $Operation; Operator = $operator; Value = $compare; Check32BitOn64System = [bool]$Check32BitOn64System }
        }
        'Script' {
            if ([string]::IsNullOrWhiteSpace($ScriptContent)) { throw 'Select a detection script.' }
            @{ Type = 'Script'; ScriptContent = $ScriptContent; RunAs32Bit = [bool]$RunAs32Bit; EnforceSignatureCheck = [bool]$EnforceSignatureCheck }
        }
    }
}

function ConvertTo-IwaGraphRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)

    $operator = if ($Rule.Operator) { [string]$Rule.Operator } else { 'notConfigured' }
    switch ([string]$Rule.Type) {
        'MsiProductCode' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppProductCodeRule'; ruleType = 'detection'
                productCode = $Rule.ProductCode; productVersionOperator = 'notConfigured'; productVersion = $null
            }
        }
        'File' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppFileSystemRule'; ruleType = 'detection'
                path = $Rule.Path; fileOrFolderName = $Rule.FileOrFolderName; check32BitOn64System = [bool]$Rule.Check32BitOn64System
                operationType = $Rule.Operation; operator = $operator; comparisonValue = $Rule.Value
            }
        }
        'Registry' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'detection'
                keyPath = $Rule.KeyPath; valueName = $Rule.ValueName; check32BitOn64System = [bool]$Rule.Check32BitOn64System
                operationType = $Rule.Operation; operator = $operator; comparisonValue = $Rule.Value
            }
        }
        'Script' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'
                displayName = $null; enforceSignatureCheck = [bool]$Rule.EnforceSignatureCheck; runAs32Bit = [bool]$Rule.RunAs32Bit
                runAsAccount = $null; operationType = 'notConfigured'; operator = 'notConfigured'; comparisonValue = $null
                scriptContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Rule.ScriptContent))
            }
        }
        'Raw' { $Rule.Graph }
        default { throw "Unknown detection rule type '$($Rule.Type)'." }
    }
}

function ConvertFrom-IwaGraphRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$GraphRule)

    # Anything the form cannot edit is kept as-is and sent back unchanged.
    $raw = @{ Type = 'Raw'; Graph = $GraphRule }
    if ([string]$GraphRule.ruleType -ne 'detection') { return $raw }
    switch ([string]$GraphRule.'@odata.type') {
        '#microsoft.graph.win32LobAppProductCodeRule' {
            if ($GraphRule.productVersionOperator -and $GraphRule.productVersionOperator -ne 'notConfigured') { return $raw }
            return @{ Type = 'MsiProductCode'; ProductCode = [string]$GraphRule.productCode }
        }
        '#microsoft.graph.win32LobAppFileSystemRule' {
            return @{
                Type = 'File'; Path = [string]$GraphRule.path; FileOrFolderName = [string]$GraphRule.fileOrFolderName
                Operation = [string]$GraphRule.operationType; Operator = [string]$GraphRule.operator; Value = $GraphRule.comparisonValue
                Check32BitOn64System = [bool]$GraphRule.check32BitOn64System
            }
        }
        '#microsoft.graph.win32LobAppRegistryRule' {
            return @{
                Type = 'Registry'; KeyPath = [string]$GraphRule.keyPath; ValueName = [string]$GraphRule.valueName
                Operation = [string]$GraphRule.operationType; Operator = [string]$GraphRule.operator; Value = $GraphRule.comparisonValue
                Check32BitOn64System = [bool]$GraphRule.check32BitOn64System
            }
        }
        '#microsoft.graph.win32LobAppPowerShellScriptRule' {
            # Without content, a script rule rebuilt here would wipe the script in Intune.
            if (-not $GraphRule.scriptContent) { return $raw }
            if ($GraphRule.operationType -and $GraphRule.operationType -ne 'notConfigured') { return $raw }
            try { $bytes = [Convert]::FromBase64String([string]$GraphRule.scriptContent) } catch { return $raw }
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            # Only text that re-encodes to the same bytes is editable; UTF-16 or ANSI scripts stay raw so Intune's copy is not altered.
            if ($text.Contains([char]0) -or [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text)) -ne [string]$GraphRule.scriptContent) { return $raw }
            return @{
                Type = 'Script'
                ScriptContent = $text
                RunAs32Bit = [bool]$GraphRule.runAs32Bit; EnforceSignatureCheck = [bool]$GraphRule.enforceSignatureCheck
            }
        }
    }
    $raw
}

function New-IwaWin32AppBody {
    <#
    .SYNOPSIS
    Builds the win32LobApp body for POST (create) or PATCH (-ForUpdate).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Spec,
        $Package,
        [switch]$ForUpdate
    )

    $body = [ordered]@{
        '@odata.type'                  = '#microsoft.graph.win32LobApp'
        displayName                    = $Spec.DisplayName
        description                    = $Spec.Description
        publisher                      = $Spec.Publisher
        displayVersion                 = $Spec.DisplayVersion
        installCommandLine             = $Spec.InstallCommandLine
        uninstallCommandLine           = $Spec.UninstallCommandLine
        minimumSupportedWindowsRelease = $Spec.MinimumWindowsRelease
        installExperience              = [ordered]@{
            '@odata.type'         = '#microsoft.graph.win32LobAppInstallExperience'
            runAsAccount          = $Spec.RunAsAccount
            deviceRestartBehavior = $Spec.DeviceRestartBehavior
            maxRunTimeInMinutes   = [int]$Spec.MaxRunTimeInMinutes
        }
        rules                          = @(@($Spec.Rules) | Where-Object { $_ } | ForEach-Object { ConvertTo-IwaGraphRule -Rule $_ })
    }
    $archList = @($Spec.Architectures) -join ','
    if ($Spec.ArchitectureProperty -eq 'allowedArchitectures') {
        # Apps created in the portal use allowedArchitectures and set applicableArchitectures to 'none'.
        $body.allowedArchitectures = $archList
        $body.applicableArchitectures = 'none'
    } else {
        $body.applicableArchitectures = $archList
    }
    if (-not $ForUpdate) {
        # The same default return codes the Intune portal adds to a new Win32 app.
        $body.returnCodes = @(
            [ordered]@{ returnCode = 0; type = 'success' },
            [ordered]@{ returnCode = 1707; type = 'success' },
            [ordered]@{ returnCode = 3010; type = 'softReboot' },
            [ordered]@{ returnCode = 1641; type = 'hardReboot' },
            [ordered]@{ returnCode = 1618; type = 'retry' }
        )
        $body.isFeatured = $false
        $body.notes = ''
        $body.owner = ''
        $body.developer = ''
    }
    if ($Package) {
        $body.fileName = Split-Path ([string]$Package.Path) -Leaf
        $body.setupFilePath = $Package.SetupFile
        if ($Package.MsiInfo) {
            $packageType = switch ([string]$Package.MsiInfo.ExecutionContext) { 'User' { 'perUser' } 'Any' { 'dualPurpose' } default { 'perMachine' } }
            $body.msiInformation = [ordered]@{
                productCode    = $Package.MsiInfo.ProductCode
                productVersion = $Package.MsiInfo.ProductVersion
                upgradeCode    = $Package.MsiInfo.UpgradeCode
                requiresReboot = [bool]$Package.MsiInfo.RequiresReboot
                packageType    = $packageType
                productName    = $Spec.DisplayName
                publisher      = $Package.MsiInfo.Publisher
            }
        }
    }
    $body
}

function ConvertFrom-IwaGraphApp {
    <#
    .SYNOPSIS
    Turns a win32LobApp read from Graph into form values.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$App)

    $experience = $App.installExperience
    $arch = [string]$App.applicableArchitectures
    $archProperty = 'applicableArchitectures'
    if (-not $arch -or $arch -eq 'none') { $arch = [string]$App.allowedArchitectures; $archProperty = 'allowedArchitectures' }
    [ordered]@{
        DisplayName           = [string]$App.displayName
        Publisher             = [string]$App.publisher
        DisplayVersion        = [string]$App.displayVersion
        Description           = [string]$App.description
        InstallCommandLine    = [string]$App.installCommandLine
        UninstallCommandLine  = [string]$App.uninstallCommandLine
        RunAsAccount          = $(if ($experience -and $experience.runAsAccount) { [string]$experience.runAsAccount } else { 'system' })
        DeviceRestartBehavior = $(if ($experience -and $experience.deviceRestartBehavior) { [string]$experience.deviceRestartBehavior } else { 'basedOnReturnCode' })
        MaxRunTimeInMinutes   = $(if ($experience -and $experience.maxRunTimeInMinutes) { [int]$experience.maxRunTimeInMinutes } else { 60 })
        ArchitectureProperty  = $archProperty
        Architectures         = @($arch -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'none' })
        MinimumWindowsRelease = $(if ($App.minimumSupportedWindowsRelease) { [string]$App.minimumSupportedWindowsRelease } else { $script:IwaWindowsReleases[0] })
        Rules                 = @(@($App.rules) | Where-Object { $_ } | ForEach-Object { ConvertFrom-IwaGraphRule -GraphRule $_ })
    }
}

function Test-IwaWin32AppSpec {
    <#
    .SYNOPSIS
    Validates the form values; streams one {Field; Message} object per problem.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Spec,
        $Package,
        [bool]$UploadContent
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $add = { param($Field, $Message) $errors.Add([pscustomobject]@{ Field = $Field; Message = $Message }) }

    $required = [ordered]@{ DisplayName = 'Name'; Publisher = 'Publisher'; Description = 'Description'; InstallCommandLine = 'Install command'; UninstallCommandLine = 'Uninstall command' }
    foreach ($key in $required.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$Spec[$key])) { & $add $key "$($required[$key]) is required." }
    }
    $minutes = 0
    if (-not [int]::TryParse([string]$Spec.MaxRunTimeInMinutes, [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) {
        & $add 'MaxRunTimeInMinutes' 'Max run time must be a number of minutes between 1 and 1440.'
    }
    if (-not @($Spec.Architectures | Where-Object { $_ }).Count) { & $add 'Architectures' 'Select at least one architecture.' }

    $rules = @($Spec.Rules | Where-Object { $_ })
    if (-not @($rules | Where-Object { $_.Type -ne 'Raw' -or $_.Graph.ruleType -eq 'detection' }).Count) {
        & $add 'Rules' 'Add at least one detection rule.'
    }
    foreach ($rule in $rules) {
        if ($rule.Type -eq 'Script' -and [System.Text.Encoding]::UTF8.GetByteCount([string]$rule.ScriptContent) -gt 200KB) {
            & $add 'Rules' 'A detection script is larger than 200 KB.'
        }
    }
    if (@($rules | Where-Object { $_.Type -eq 'Raw' -and $_.Graph.'@odata.type' -eq '#microsoft.graph.win32LobAppPowerShellScriptRule' -and -not $_.Graph.scriptContent }).Count) {
        & $add 'Rules' 'A script rule of this app came back from Intune without its content. Edit this app''s script rules in the portal ("Open in Intune").'
    }
    if ($UploadContent -and -not $Package) { & $add 'PackagePath' 'Select a valid .intunewin package to upload.' }

    $errors.ToArray()
}

function Get-IwaRuleSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)

    $check = if ($Rule.Operation -eq 'exists' -or -not $Rule.Operator -or $Rule.Operator -eq 'notConfigured') {
        [string]$Rule.Operation
    } else {
        '{0} {1} {2}' -f $Rule.Operation, $Rule.Operator, $Rule.Value
    }
    switch ([string]$Rule.Type) {
        'MsiProductCode' { "MSI product code $($Rule.ProductCode)" }
        'File' { 'File: {0}\{1}: {2}' -f ([string]$Rule.Path).TrimEnd('\'), $Rule.FileOrFolderName, $check }
        'Registry' {
            $value = if ($Rule.ValueName) { " [$($Rule.ValueName)]" } else { '' }
            'Registry: {0}{1}: {2}' -f $Rule.KeyPath, $value, $check
        }
        'Script' { 'PowerShell script ({0:N0} characters)' -f ([string]$Rule.ScriptContent).Length }
        'Raw' { 'Kept from Intune: {0} ({1})' -f ([string]$Rule.Graph.'@odata.type').Replace('#microsoft.graph.', ''), $Rule.Graph.ruleType }
        default { [string]$Rule.Type }
    }
}
