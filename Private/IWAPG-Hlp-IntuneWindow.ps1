# IWAPG-Hlp-IntuneWindow.ps1
# "Publish to Intune" window: create or update a Win32 app from a .intunewin package.

$script:IwaV1Limitations = 'Not handled here yet: assignments, icon, supersedence, dependencies, custom return codes (Intune defaults are used). Use "Open in Intune" to set them in the portal.'

function Get-IwaIntuneWindowControlName {
    @(
        'ModeNew', 'ModeUpdate', 'AccountText', 'InstallGraphButton', 'SignInButton', 'GraphStatusText', 'LimitsText',
        'FormPanel', 'SearchPanel', 'SearchBox', 'SearchButton', 'SearchResults',
        'PackagePath', 'BrowsePackage', 'UploadContent',
        'DisplayName', 'Publisher', 'DisplayVersion', 'Description',
        'InstallCommandLine', 'UninstallCommandLine', 'RunAsAccount', 'DeviceRestartBehavior', 'MaxRunTimeInMinutes',
        'ArchX64', 'ArchX86', 'ArchArm64', 'MinimumWindowsRelease',
        'RulesList', 'RemoveRuleButton', 'NewRuleType', 'MsiRulePanel', 'RuleProductCode',
        'FileRulePanel', 'RuleFilePath', 'RuleFileName', 'RuleFileOperation', 'RuleFileValue', 'RuleFile32Bit',
        'RegistryRulePanel', 'RuleKeyPath', 'RuleValueName', 'RuleRegOperation', 'RuleRegValue', 'RuleReg32Bit',
        'ScriptRulePanel', 'RuleScriptPath', 'BrowseScript', 'RuleScriptRunAs32', 'RuleScriptSignature',
        'AddRuleButton', 'RuleErrorText',
        'ValidationText', 'StatusText', 'ProgressPanel', 'ProgressText', 'UploadProgress',
        'OpenInIntune', 'RetryUploadButton', 'UploadButton', 'CloseButton'
    )
}

function Get-IwaIntuneWindowXaml {
    <#
    .SYNOPSIS
    Returns IntuneWindow.xaml with the styles of UI.xaml injected, so both windows share one style source.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleRoot)

    $main = Get-Content -LiteralPath (Join-Path $ModuleRoot 'UI\UI.xaml') -Raw
    $resources = [regex]::Match($main, '(?s)<Window\.Resources>.*?</Window\.Resources>')
    if (-not $resources.Success) { throw 'Window.Resources not found in UI.xaml.' }
    (Get-Content -LiteralPath (Join-Path $ModuleRoot 'UI\IntuneWindow.xaml') -Raw).Replace('<!-- SHARED_RESOURCES -->', $resources.Value)
}
