# IWAPG-Hlp-IntuneWindow.ps1
# "Publish to Intune" tab of the main window: create or update a Win32 app from a .intunewin package.

$script:IwaV1Limitations = 'Not handled here yet: assignments, icon, supersedence, dependencies, custom return codes (Intune defaults are used). Use "Open in Intune" to set them in the portal.'

function Get-IwaIntuneWindowControlName {
    @(
        'ModeNew', 'ModeUpdate', 'AccountText', 'InstallGraphButton', 'SignInButton', 'GraphStatusText', 'LimitsText',
        'FormPanel', 'SearchPanel', 'SearchBox', 'SearchButton', 'SearchResults',
        'PackagePath', 'BrowsePackage', 'UploadContent',
        'DisplayName', 'Publisher', 'DisplayVersion', 'Description',
        'InstallCommandLine', 'UninstallCommandLine', 'RunAsAccount', 'DeviceRestartBehavior', 'MaxRunTimeInMinutes',
        'ArchX64', 'ArchX86', 'ArchArm64', 'ArchKeptText', 'MinimumWindowsRelease',
        'RulesList', 'RemoveRuleButton', 'NewRuleType', 'MsiRulePanel', 'RuleProductCode',
        'FileRulePanel', 'RuleFilePath', 'RuleFileName', 'RuleFileOperation', 'RuleFileValue', 'RuleFile32Bit',
        'RegistryRulePanel', 'RuleKeyPath', 'RuleValueName', 'RuleRegOperation', 'RuleRegValue', 'RuleReg32Bit',
        'ScriptRulePanel', 'RuleScriptPath', 'BrowseScript', 'RuleScriptRunAs32', 'RuleScriptSignature',
        'AddRuleButton', 'RuleErrorText',
        'ValidationText', 'StatusText', 'ProgressPanel', 'ProgressText', 'UploadProgress',
        'OpenInIntune', 'RetryUploadButton', 'UploadButton', 'ConnectionAppText', 'AccountAvatarText', 'MethodChip', 'AlphaBadge', 'SignInMenuButton',
        'ConnectionOverlay', 'ConnectionClientId', 'ConnectionTenantId', 'ConnectionError', 'ConnectionSave', 'ConnectionCancel', 'ConnectionUseMicrosoft',
        'DoneOverlay', 'DoneTitle', 'DoneAppName', 'DoneDetail', 'DoneNote', 'DoneOpenIntune', 'DoneBack'
    )
}

function Get-IwaMainWindowXaml {
    <#
    .SYNOPSIS
    Returns UI.xaml with the "Publish to Intune" tab (IntunePanel.xaml) injected, so both share one name scope and one set of styles.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleRoot)

    $marker = '<!-- INTUNE_PANEL -->'
    $main = Get-Content -LiteralPath (Join-Path $ModuleRoot 'UI\UI.xaml') -Raw
    if (-not $main.Contains($marker)) { throw "$marker not found in UI.xaml." }
    $main.Replace($marker, (Get-Content -LiteralPath (Join-Path $ModuleRoot 'UI\IntunePanel.xaml') -Raw))
}

# Runs in a second runspace of the same process, so it shares the Connect-MgGraph sign-in
# (checked by Tools/Test-IwaGraphSpike.ps1). Reports through the synchronized $State hashtable.
$script:IwaIntuneTaskScript = {
    param($State, $ModuleRoot, $Body, $Package)
    $ErrorActionPreference = 'Stop'
    $work = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($helper in @('IWAPG-Hlp-IntunePackage.ps1', 'IWAPG-Hlp-IntuneGraph.ps1')) {
            . (Join-Path $ModuleRoot "Private\$helper")
        }
        Import-Module Microsoft.Graph.Authentication

        # Update + new package: the settings go in the same PATCH that commits the new content,
        # so a failed upload leaves both settings and content as they were.
        $appBody = $null
        if (-not $State.AppId) {
            $State.Step = 'Creating the app in Intune'
            $State.AppId = (Invoke-IwaGraph -Method POST -Uri $script:IwaGraphAppsUri -Body $Body).id
            $State.Saved = $true
        } elseif ($Body -and $Package) {
            $appBody = $Body
        } elseif ($Body) {
            $State.Step = 'Saving the app settings'
            Invoke-IwaGraph -Method PATCH -Uri "$script:IwaGraphAppsUri/$($State.AppId)" -Body $Body | Out-Null
            $State.Saved = $true
        }

        if ($Package) {
            $State.Step = 'Extracting the encrypted content'
            $work = Join-Path ([System.IO.Path]::GetTempPath()) ('IwaUpload-' + [guid]::NewGuid())
            $content = Expand-IwaIntuneWinContent -Package $Package -Destination $work
            $State.Step = 'Uploading the content'
            $publishArgs = @{}
            if ($appBody) { $publishArgs.AppBody = $appBody }
            Publish-IwaWin32AppContent -AppId $State.AppId -Package $Package -ContentFile $content @publishArgs -OnProgress {
                param($sent, $total)
                $State.Percent = [int](100 * $sent / [Math]::Max(1, $total))
                $State.Step = if ($sent -ge $total) { 'Waiting for Intune to process the content (this can take a few minutes)' }
                              else { 'Uploading the content ({0:N1} of {1:N1} MB)' -f ($sent / 1MB), ($total / 1MB) }
            } | Out-Null
        }
        $State.Done = $true
    } catch {
        $State.Error = if (Get-Command Get-IwaGraphErrorMessage -ErrorAction SilentlyContinue) { Get-IwaGraphErrorMessage -ErrorRecord $_ } else { $_.Exception.Message }
        # No HTTP answer (or a timeout/server error): the request may still have been carried out.
        $State.NoAnswer = if (Get-Command Test-IwaTransientHttpError -ErrorAction SilentlyContinue) { Test-IwaTransientHttpError -ErrorRecord $_ } else { $true }
    } finally {
        if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Initialize-IwaIntunePanel {
    <#
    .SYNOPSIS
    Wires the "Publish to Intune" tab of the main window (parsed from Get-IwaMainWindowXaml).
    .DESCRIPTION
    Dot-source it from Show-IntuneWinAppUtilGUI (". Initialize-IwaIntunePanel ..."): its variables then live in the
    main window's scope, which stays alive while the window is open, so the handlers below keep reaching them.
    The main window uses:
      $iwaActivate      first time the tab is shown: checks the Graph module and the sign-in
      $iwaSetConnection param($ClientId, $TenantId, $Method): the app registration and sign-in method from config.json
      $iwaHideConnection closes the Connection settings panel; $iwaSaveConnection saves it
      $iwaOpenPackage   param($PackagePath, $DisplayVersion, $DisplayName, $Publisher): loads a package into the form
      $iwaUploadRunning $true while an upload runs
      $iwaStopUpload    stops a running upload without waiting for it
      $iwaReleaseFinishedUpload  frees an upload that ended but was not collected yet
    #>
    param($IwaWindow, [string]$ModuleRoot)

    $win = $IwaWindow
    $ui = @{}
    foreach ($name in Get-IwaIntuneWindowControlName) { $ui[$name] = $win.FindName($name) }

    # An assignment inside a handler creates a local variable: every value a handler changes lives in $state.
    $state = @{
        Package = $null; DisplayVersion = $null; DisplayName = $null; Publisher = $null; AppId = $null; Account = $null; Activated = $false
        Rules = New-Object System.Collections.ArrayList
        SearchResults = @(); LoadedApp = $null; Task = $null
        ArchitectureProperty = ''; ArchitectureCheck = $true; KeepIntuneRules = $false; Waiting = $false; LoadingIndex = -1; ClientId = ''; TenantId = ''; UseAppRegistration = $false; ConfigWarning = $null; ConfigClientId = ''; ConfigTenantId = ''; ExtraArchitectures = @(); Busy = $false; Loading = $false; LoadingResults = $false; KeepAppId = $false; LastUpload = $false
        InstallError = $null; SignInError = $null; SearchError = $null; LoadError = $null
    }
    $errorBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xC0, 0x39, 0x2B))
    $successBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1E, 0x7B, 0x34))
    $visible = [System.Windows.Visibility]::Visible
    $collapsed = [System.Windows.Visibility]::Collapsed
    $fieldControls = @('DisplayName', 'Publisher', 'Description', 'InstallCommandLine', 'UninstallCommandLine', 'MaxRunTimeInMinutes', 'PackagePath', 'RulesList')

    $ui.LimitsText.Text = $script:IwaV1Limitations
    foreach ($release in $script:IwaWindowsReleases) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = Get-IwaWindowsReleaseLabel -Release $release
        $item.Tag = $release
        [void]$ui.MinimumWindowsRelease.Items.Add($item)
    }

    # --- Helpers ------------------------------------------------------------------------------
    $doEvents = {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $null = $win.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; $null },
            $frame)
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    # shortcut: sign-in, install, search and app loading block the window while they run (seconds);
    # move them to the background task if large tenants make that noticeable.
    # Clicks made while it waits are dropped (the panel ignores the mouse until they are drained),
    # so a queued click cannot run a second sign-in, search or load.
    $panelRoot = $win.FindName('IntunePanel')
    $withWait = {
        param([scriptblock]$Action)
        if ($state.Waiting) { return }
        $state.Waiting = $true
        $panelRoot.IsHitTestVisible = $false
        $win.Cursor = [System.Windows.Input.Cursors]::Wait
        & $doEvents
        try { & $Action } finally {
            & $doEvents
            $win.Cursor = $null
            $panelRoot.IsHitTestVisible = $true
            $state.Waiting = $false
        }
    }
    $selectByTag = {
        param($Combo, $Tag)
        foreach ($item in $Combo.Items) {
            if ([string]$item.Tag -eq [string]$Tag) { $Combo.SelectedItem = $item; return }
        }
        if ($Combo -eq $ui.MinimumWindowsRelease -and $Tag) {
            # Keep a release set in the portal even if it is not in the list.
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = Get-IwaWindowsReleaseLabel -Release $Tag
            $item.Tag = $Tag
            [void]$Combo.Items.Add($item)
            $Combo.SelectedItem = $item
            return
        }
        $Combo.SelectedIndex = 0
    }
    $showStatus = {
        param([string]$Kind, [string]$Text)
        $ui.StatusText.Text = $Text
        $ui.StatusText.Foreground = if ($Kind -eq 'error') { $errorBrush } else { $successBrush }
        $ui.StatusText.Visibility = $visible
    }
    $hideStatus = { $ui.StatusText.Visibility = $collapsed }

    $emptySpec = {
        [ordered]@{
            DisplayName = ''; Publisher = ''; DisplayVersion = ''; Description = ''
            InstallCommandLine = ''; UninstallCommandLine = ''
            RunAsAccount = 'system'; DeviceRestartBehavior = 'basedOnReturnCode'; MaxRunTimeInMinutes = 60
            Architectures = @('x64'); MinimumWindowsRelease = $script:IwaWindowsReleases[0]; Rules = @()
        }
    }
    $getForm = {
        $arch = @()
        if ($ui.ArchX64.IsChecked) { $arch += 'x64' }
        if ($ui.ArchX86.IsChecked) { $arch += 'x86' }
        if ($ui.ArchArm64.IsChecked) { $arch += 'arm64' }
        $arch += @($state.ExtraArchitectures)
        [ordered]@{
            DisplayName           = $ui.DisplayName.Text.Trim()
            Publisher             = $ui.Publisher.Text.Trim()
            DisplayVersion        = $ui.DisplayVersion.Text.Trim()
            Description           = $ui.Description.Text.Trim()
            InstallCommandLine    = $ui.InstallCommandLine.Text.Trim()
            UninstallCommandLine  = $ui.UninstallCommandLine.Text.Trim()
            RunAsAccount          = [string]$ui.RunAsAccount.SelectedItem.Tag
            DeviceRestartBehavior = [string]$ui.DeviceRestartBehavior.SelectedItem.Tag
            MaxRunTimeInMinutes   = $ui.MaxRunTimeInMinutes.Text.Trim()
            ArchitectureProperty  = $state.ArchitectureProperty
            ArchitectureCheck     = $state.ArchitectureCheck
            KeepIntuneRules       = $state.KeepIntuneRules
            Architectures         = $arch
            MinimumWindowsRelease = [string]$ui.MinimumWindowsRelease.SelectedItem.Tag
            Rules                 = @($state.Rules)
        }
    }
    $validate = {
        if ($state.Loading) { return }
        $errors = @(Test-IwaWin32AppSpec -Spec (& $getForm) -Package $state.Package -UploadContent ([bool]$ui.UploadContent.IsChecked))
        if ($ui.ModeUpdate.IsChecked -and -not $state.AppId) { $errors += [pscustomobject]@{ Field = 'SearchResults'; Message = 'Select the app to update.' } }
        if (-not $state.Account) { $errors += [pscustomobject]@{ Field = 'SignInButton'; Message = 'Sign in to Intune.' } }
        foreach ($name in $fieldControls) { $ui[$name].ClearValue([System.Windows.Controls.Control]::BorderBrushProperty) }
        foreach ($err in $errors) {
            $target = if ($err.Field -eq 'Rules') { 'RulesList' } else { [string]$err.Field }
            if ($fieldControls -contains $target) { $ui[$target].BorderBrush = $errorBrush }
        }
        $warnings = @()
        $msiRule = @($state.Rules | Where-Object { $_.Type -eq 'MsiProductCode' }) | Select-Object -First 1
        if ($ui.ModeUpdate.IsChecked -and $ui.UploadContent.IsChecked -and $state.Package.MsiInfo -and $msiRule -and $msiRule.ProductCode -ne $state.Package.MsiInfo.ProductCode) {
            $warnings += 'The package''s MSI product code differs from the detection rule; update the rule if this is a major upgrade.'
        }
        $lines = @($errors | ForEach-Object { $_.Message }) + $warnings
        # One paragraph, not one line per message: the tab has the height of the Package tab.
        $ui.ValidationText.Text = ($lines -join ("  {0}  " -f [char]0x00B7))
        $ui.ValidationText.Visibility = if ($lines.Count -and -not $state.Busy) { $visible } else { $collapsed }
        $ui.UploadButton.IsEnabled = ($errors.Count -eq 0) -and -not $state.Busy
    }
    $refreshRules = {
        $ui.RulesList.Items.Clear()
        foreach ($rule in $state.Rules) { [void]$ui.RulesList.Items.Add((Get-IwaRuleSummary -Rule $rule)) }
        & $validate
    }
    $setForm = {
        param($Spec)
        $state.Loading = $true
        $state.KeepIntuneRules = $false
        try {
            $ui.DisplayName.Text = [string]$Spec.DisplayName
            $ui.Publisher.Text = [string]$Spec.Publisher
            $ui.DisplayVersion.Text = [string]$Spec.DisplayVersion
            $ui.Description.Text = [string]$Spec.Description
            $ui.InstallCommandLine.Text = [string]$Spec.InstallCommandLine
            $ui.UninstallCommandLine.Text = [string]$Spec.UninstallCommandLine
            $ui.MaxRunTimeInMinutes.Text = [string]$Spec.MaxRunTimeInMinutes
            & $selectByTag $ui.RunAsAccount $Spec.RunAsAccount
            & $selectByTag $ui.DeviceRestartBehavior $Spec.DeviceRestartBehavior
            & $selectByTag $ui.MinimumWindowsRelease $Spec.MinimumWindowsRelease
            $state.ArchitectureProperty = [string]$Spec.ArchitectureProperty
            $arch = @($Spec.Architectures)
            $ui.ArchX64.IsChecked = $arch -contains 'x64'
            $ui.ArchX86.IsChecked = $arch -contains 'x86'
            $ui.ArchArm64.IsChecked = $arch -contains 'arm64'
            $state.ExtraArchitectures = @($arch | Where-Object { $_ -and $_ -notin @('x64', 'x86', 'arm64') })
            # Only an app read from Intune can have no architecture check; new apps always check it.
            $state.ArchitectureCheck = ($Spec.ArchitectureCheck -ne $false)
            $ui.ArchKeptText.Text = if (-not $state.ArchitectureCheck) { 'Not checked in Intune: leave all unchecked to keep it so.' }
                                    else { 'Also kept: ' + ($state.ExtraArchitectures -join ', ') }
            $ui.ArchKeptText.Visibility = if ($state.ExtraArchitectures.Count -or -not $state.ArchitectureCheck) { $visible } else { $collapsed }
            $state.Rules.Clear()
            foreach ($rule in @($Spec.Rules | Where-Object { $_ })) { [void]$state.Rules.Add($rule) }
        } finally {
            $state.Loading = $false
        }
        & $refreshRules
    }
    # Updating an app with new content: the version is the package's, not the one of the app in Intune.
    $applyPackageVersion = {
        if (-not ($ui.ModeUpdate.IsChecked -and $ui.UploadContent.IsChecked -and $state.Package)) { return }
        $version = (Get-IwaWin32AppDefault -Package $state.Package -DisplayVersion $state.DisplayVersion).DisplayVersion
        if ($version) { $ui.DisplayVersion.Text = $version }
    }
    $loadPackage = {
        param([string]$Path)
        $state.Package = $null
        $ui.PackagePath.Text = $Path
        # A retry sends the old package's content; after a new package the user must Upload again.
        $ui.RetryUploadButton.Visibility = $collapsed
        if ($Path) {
            try { $state.Package = Read-IwaIntuneWinPackage -Path $Path }
            catch { & $showStatus 'error' $_.Exception.Message }
        }
        if ($state.Package -and $ui.ModeNew.IsChecked) {
            & $setForm (Get-IwaWin32AppDefault -Package $state.Package -DisplayVersion $state.DisplayVersion -DisplayName $state.DisplayName -Publisher $state.Publisher)
        } else {
            if ($state.AppId) { & $applyPackageVersion }
            & $validate
        }
    }
    # The app registration in use: only when that method is chosen (its values stay saved otherwise).
    $activeClientId = { if ($state.UseAppRegistration) { $state.ClientId } else { '' } }
    $activeTenantId = { if ($state.UseAppRegistration) { $state.TenantId } else { '' } }
    $brush = { param([string]$Hex) (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
    # Account block: avatar, account, method chip (blue: Microsoft, orange + ALPHA: app registration), Sign in/out.
    $renderAccountBlock = {
        $useApp = [bool]$state.UseAppRegistration
        $ui.ConnectionAppText.Text = if ($useApp) { 'App registration {0}...' -f $state.ClientId.Substring(0, 8) } else { 'Microsoft account' }
        $ui.MethodChip.Background = & $brush $(if ($useApp) { '#FFF8EE' } else { '#EEF6FF' })
        $ui.MethodChip.BorderBrush = & $brush $(if ($useApp) { '#F5D0A0' } else { '#C5DCF6' })
        $ui.ConnectionAppText.Foreground = & $brush $(if ($useApp) { '#7A3E00' } else { '#33536F' })
        $ui.AlphaBadge.Visibility = if ($useApp) { $visible } else { $collapsed }
        $ui.AccountText.Text = if ($state.Account) { [string]$state.Account } else { 'Not signed in' }
        if ($state.Account) {
            # Initials of the account name, or the person glyph when signed out.
            $parts = @((([string]$state.Account -split '@')[0] -split '[._-]+') | ForEach-Object { $_ -replace '[^\p{L}\p{N}]', '' } | Where-Object { $_ })
            $initials = if ($parts.Count -ge 2) { "$($parts[0][0])$($parts[1][0])" } elseif ($parts.Count) { $parts[0].Substring(0, [Math]::Min(2, $parts[0].Length)) } else { '?' }
            $ui.AccountAvatarText.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
            $ui.AccountAvatarText.Text = $initials.ToUpperInvariant()
        } else {
            $ui.AccountAvatarText.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
            $ui.AccountAvatarText.Text = [string][char]0xE77B
        }
        $ui.SignInButton.Content = if ($state.Account) { 'Sign out' } else { 'Sign in' }
        # Primary while signed out (the next step), plain once signed in.
        foreach ($button in @($ui.SignInButton, $ui.SignInMenuButton)) {
            if ($state.Account) { $button.ClearValue([System.Windows.FrameworkElement]::StyleProperty) }
            else { $button.Style = $win.FindResource('PrimaryButtonStyle') }
        }
    }
    $refreshAccount = {
        $hasModule = Test-IwaGraphModule
        $ui.InstallGraphButton.Visibility = if ($hasModule) { $collapsed } else { $visible }
        $ui.SignInButton.IsEnabled = $hasModule
        $state.Account = $null
        if ($hasModule) {
            try { $state.Account = Get-IwaIntuneAccount -ClientId (& $activeClientId) -TenantId (& $activeTenantId) } catch { Write-IwaDebugLog "Reading the Graph context failed: $($_.Exception.Message)" }
            $ui.GraphStatusText.Text = $state.ConfigWarning
            $ui.GraphStatusText.Visibility = if ($state.ConfigWarning) { $visible } else { $collapsed }
        } else {
            $ui.GraphStatusText.Text = 'Publishing needs the Microsoft.Graph.Authentication module. Select Install now, or run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
            $ui.GraphStatusText.Visibility = $visible
        }
        & $renderAccountBlock
        $ui.SearchButton.IsEnabled = [bool]$state.Account
        & $validate
    }
    $applyMode = {
        $isNew = [bool]$ui.ModeNew.IsChecked
        $ui.SearchPanel.Visibility = if ($isNew) { $collapsed } else { $visible }
        $ui.UploadContent.IsEnabled = -not $isNew
        if ($isNew) { $ui.UploadContent.IsChecked = $true }
        $ui.RetryUploadButton.Visibility = $collapsed
        & $hideStatus
        if (-not $state.KeepAppId) {
            $state.AppId = $null
            $ui.OpenInIntune.IsEnabled = $false
            $state.LoadingResults = $true
            $ui.SearchResults.Items.Clear()
            $state.LoadingResults = $false
            if ($isNew) {
                if ($state.Package) { & $setForm (Get-IwaWin32AppDefault -Package $state.Package -DisplayVersion $state.DisplayVersion -DisplayName $state.DisplayName -Publisher $state.Publisher) }
                else { & $setForm (& $emptySpec) }
            }
        }
        & $validate
    }
    $setBusy = {
        param([bool]$Busy)
        $state.Busy = $Busy
        foreach ($control in @($ui.FormPanel, $ui.ModeNew, $ui.ModeUpdate, $ui.SignInButton)) { $control.IsEnabled = -not $Busy }
        $ui.ProgressPanel.Visibility = if ($Busy) { $visible } else { $collapsed }
        if ($Busy) { $ui.UploadButton.IsEnabled = $false; $ui.ValidationText.Visibility = $collapsed }
    }
    $startTask = {
        param($AppId, $Body, $Package)
        & $setBusy $true
        $state.LastUpload = [bool]$Package
        $ui.RetryUploadButton.Visibility = $collapsed
        & $hideStatus
        $ui.UploadProgress.Value = 0
        $ui.ProgressText.Text = 'Starting'
        $taskState = [hashtable]::Synchronized(@{
            Step = 'Starting'; Percent = 0; AppId = $AppId; Saved = ([bool]$AppId -and -not $Body); Error = $null; Done = $false
        })
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:IwaIntuneTaskScript.ToString())
        [void]$ps.AddArgument($taskState).AddArgument($ModuleRoot).AddArgument($Body).AddArgument($Package)
        $state.Task = @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); State = $taskState; IsNew = [bool]$ui.ModeNew.IsChecked }
        $timer.Start()
    }

    # --- Background task polling ---------------------------------------------------------------
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        $task = $state.Task
        if (-not $task) { $timer.Stop(); return }
        $ui.ProgressText.Text = [string]$task.State.Step
        # Before the first chunk and after the last one Intune is working with no measurable progress.
        $percent = [int]$task.State.Percent
        $ui.UploadProgress.IsIndeterminate = ($percent -le 0 -or $percent -ge 100)
        $ui.UploadProgress.Value = $percent
        if (-not $task.Handle.IsCompleted) { return }

        $timer.Stop()
        try { $null = $task.PowerShell.EndInvoke($task.Handle) } catch { if (-not $task.State.Error) { $task.State.Error = $_.Exception.Message } }
        $task.PowerShell.Dispose()
        $state.Task = $null
        & $setBusy $false
        if ($task.State.AppId) {
            $state.AppId = $task.State.AppId
            $ui.OpenInIntune.IsEnabled = $true
        }
        if ($task.State.Error) {
            Write-IwaDebugLog "Publish to Intune failed: $($task.State.Error)"
            $message = "Publishing failed: $($task.State.Error)"
            if ($task.IsNew -and $task.State.AppId) {
                # The app exists now: further uploads go to it, not to a second new app.
                $state.KeepAppId = $true
                $ui.ModeUpdate.IsChecked = $true
                $state.KeepAppId = $false
                $ui.UploadContent.IsChecked = [bool]$state.LastUpload
                $message += "`nThe app was created in Intune without content. Select Retry upload to send the package to the same app."
                if ($state.LastUpload) { $ui.RetryUploadButton.Visibility = $visible }
            } elseif ($task.IsNew -and $task.State.Step -eq 'Creating the app in Intune' -and $task.State.NoAnswer) {
                # The request may have reached Intune even if its answer did not come back.
                $message += "`nIf the connection dropped, the app may have been created anyway: search for it in Update existing before you upload again."
            } else {
                $message += "`nNothing was changed in Intune: settings and content are as before. Select Upload to try again."
            }
            & $showStatus 'error' $message
        } else {
            $ui.UploadContent.IsChecked = $false
            if ($task.IsNew) {
                # The app now exists: further changes are updates of the same app, not new apps.
                $state.KeepAppId = $true
                $ui.ModeUpdate.IsChecked = $true
                $state.KeepAppId = $false
            }
            & $showStatus 'success' ("Done: ""{0}"" is in Intune.`n{1}" -f $ui.DisplayName.Text, $script:IwaV1Limitations)
            $ui.DoneTitle.Text = if ($task.IsNew) { 'App created in Intune' } else { 'App updated in Intune' }
            $ui.DoneAppName.Text = $ui.DisplayName.Text
            $ui.DoneDetail.Text = if ($state.LastUpload) { 'Settings and package content are saved. Intune can take a few minutes to show the new content.' }
                                  else { 'Settings are saved. The package content was not changed.' }
            $ui.DoneNote.Text = $script:IwaV1Limitations
            $ui.DoneOverlay.Visibility = $visible
            $ui.DoneOpenIntune.Focus() | Out-Null
        }
        & $validate
    })

    # --- Events ------------------------------------------------------------------------------
    $ui.ModeNew.Add_Checked({ & $applyMode })
    $ui.ModeUpdate.Add_Checked({ & $applyMode })

    $ui.InstallGraphButton.Add_Click({
        if ($state.Waiting) { return }
        $ui.GraphStatusText.Text = 'Installing Microsoft.Graph.Authentication for the current user...'
        $ui.GraphStatusText.Visibility = $visible
        $state.InstallError = $null
        & $withWait { try { Install-IwaGraphModule } catch { $state.InstallError = $_.Exception.Message } }
        & $refreshAccount
        if ($state.InstallError) {
            $ui.GraphStatusText.Text = "Installing the module failed: $($state.InstallError)`nRun it manually: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
            $ui.GraphStatusText.Visibility = $visible
        }
    })

    $ui.SignInButton.Add_Click({
        if ($state.Waiting) { return }
        if ($state.Account) { Disconnect-IwaIntune; & $refreshAccount; return }
        $ui.GraphStatusText.Text = 'Signing in... complete the sign-in in the window that opens.'
        $ui.GraphStatusText.Visibility = $visible
        $state.SignInError = $null
        & $withWait { try { Connect-IwaIntune -ClientId (& $activeClientId) -TenantId (& $activeTenantId) | Out-Null } catch { $state.SignInError = $_.Exception.Message } }
        & $refreshAccount
        if ($state.SignInError) {
            Write-IwaDebugLog "Intune sign-in failed: $($state.SignInError)"
            $ui.GraphStatusText.Text = Get-IwaSignInErrorMessage -Message $state.SignInError -CustomApp:([bool]$state.UseAppRegistration)
            $ui.GraphStatusText.Visibility = $visible
        }
    })

    $ui.BrowsePackage.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'Intune Win32 package (*.intunewin)|*.intunewin'
        if ($ui.PackagePath.Text) { $dialog.InitialDirectory = Split-Path $ui.PackagePath.Text -Parent }
        if ($dialog.ShowDialog($win)) {
            # Name, version and publisher from the main window belong to the package it built, not to this one.
            $state.DisplayVersion = $null; $state.DisplayName = $null; $state.Publisher = $null
            & $hideStatus
            if ($ui.ModeUpdate.IsChecked) { $ui.UploadContent.IsChecked = $true }
            & $loadPackage $dialog.FileName
        }
    })

    $runSearch = {
        if ($state.Waiting) { return }
        & $hideStatus
        $state.AppId = $null
        $ui.OpenInIntune.IsEnabled = $false
        $ui.RetryUploadButton.Visibility = $collapsed
        $state.SearchError = $null
        & $withWait {
            try { $state.SearchResults = @(Get-IwaWin32App -Search $ui.SearchBox.Text.Trim()) }
            catch { $state.SearchResults = @(); $state.SearchError = Get-IwaGraphErrorMessage -ErrorRecord $_ }
        }
        $state.LoadingResults = $true
        $ui.SearchResults.Items.Clear()
        foreach ($app in $state.SearchResults) {
            [void]$ui.SearchResults.Items.Add(('{0}  |  {1}' -f $app.displayName, $app.publisher))
        }
        $state.LoadingResults = $false
        if ($state.SearchError) { & $showStatus 'error' "Search failed: $($state.SearchError)" }
        elseif (-not $state.SearchResults.Count) { & $showStatus 'error' 'No Win32 app matches that name.' }
        & $validate
    }
    $ui.SearchButton.Add_Click({ & $runSearch })
    $ui.SearchBox.Add_KeyDown({
        param($evtSender, $e)
        if ($e.Key -eq 'Return' -and $ui.SearchButton.IsEnabled) { & $runSearch; $e.Handled = $true }
    })
    $ui.SearchResults.Add_SelectionChanged({
        $index = $ui.SearchResults.SelectedIndex
        if ($state.LoadingResults -or $index -lt 0) { return }
        if ($state.Waiting) {
            # A key pressed while another app loads: keep the list on the app the form is loading.
            $state.LoadingResults = $true
            $ui.SearchResults.SelectedIndex = $state.LoadingIndex
            $state.LoadingResults = $false
            return
        }
        $state.LoadingIndex = $index
        $picked = $state.SearchResults[$index]
        $state.AppId = $null
        $ui.OpenInIntune.IsEnabled = $false
        $ui.RetryUploadButton.Visibility = $collapsed
        $state.LoadError = $null
        $state.LoadedApp = $null
        & $withWait {
            try { $state.LoadedApp = Get-IwaWin32App -Id $picked.id }
            catch { $state.LoadError = Get-IwaGraphErrorMessage -ErrorRecord $_ }
        }
        if ($state.LoadError) { & $showStatus 'error' "Loading the app failed: $($state.LoadError)"; & $validate; return }
        $state.AppId = [string]$state.LoadedApp.id
        $ui.OpenInIntune.IsEnabled = $true
        $ui.RetryUploadButton.Visibility = $collapsed
        & $setForm (ConvertFrom-IwaGraphApp -App $state.LoadedApp)
        # Until the rules are changed here, the update leaves them as they are in Intune.
        $state.KeepIntuneRules = $true
        & $applyPackageVersion
        & $validate
        & $showStatus 'success' ('Loaded "{0}". Change what you need, then select Upload.' -f $state.LoadedApp.displayName)
    })

    $ui.NewRuleType.Add_SelectionChanged({
        $type = [string]$ui.NewRuleType.SelectedItem.Tag
        $ui.MsiRulePanel.Visibility = if ($type -eq 'MsiProductCode') { $visible } else { $collapsed }
        $ui.FileRulePanel.Visibility = if ($type -eq 'File') { $visible } else { $collapsed }
        $ui.RegistryRulePanel.Visibility = if ($type -eq 'Registry') { $visible } else { $collapsed }
        $ui.ScriptRulePanel.Visibility = if ($type -eq 'Script') { $visible } else { $collapsed }
        $ui.RuleErrorText.Visibility = $collapsed
    })
    # "Exists" compares nothing, so the value box only shows for the other operations.
    $ui.RuleFileOperation.Add_SelectionChanged({
        $ui.RuleFileValue.Visibility = if ([string]$ui.RuleFileOperation.SelectedItem.Tag -eq 'exists') { [System.Windows.Visibility]::Hidden } else { $visible }
    })
    $ui.RuleRegOperation.Add_SelectionChanged({
        $ui.RuleRegValue.Visibility = if ([string]$ui.RuleRegOperation.SelectedItem.Tag -eq 'exists') { [System.Windows.Visibility]::Hidden } else { $visible }
    })
    $ui.BrowseScript.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'PowerShell script (*.ps1)|*.ps1'
        if ($dialog.ShowDialog($win)) { $ui.RuleScriptPath.Text = $dialog.FileName }
    })
    $ui.AddRuleButton.Add_Click({
        $type = [string]$ui.NewRuleType.SelectedItem.Tag
        $ruleArgs = @{ Type = $type }
        try {
            switch ($type) {
                'MsiProductCode' { $ruleArgs.ProductCode = $ui.RuleProductCode.Text.Trim() }
                'File' {
                    $ruleArgs.Path = $ui.RuleFilePath.Text
                    $ruleArgs.FileOrFolderName = $ui.RuleFileName.Text
                    $ruleArgs.Operation = [string]$ui.RuleFileOperation.SelectedItem.Tag
                    $ruleArgs.Value = $ui.RuleFileValue.Text
                    $ruleArgs.Check32BitOn64System = [bool]$ui.RuleFile32Bit.IsChecked
                }
                'Registry' {
                    $ruleArgs.KeyPath = $ui.RuleKeyPath.Text
                    $ruleArgs.ValueName = $ui.RuleValueName.Text
                    $ruleArgs.Operation = [string]$ui.RuleRegOperation.SelectedItem.Tag
                    $ruleArgs.Value = $ui.RuleRegValue.Text
                    $ruleArgs.Check32BitOn64System = [bool]$ui.RuleReg32Bit.IsChecked
                }
                'Script' {
                    $scriptPath = $ui.RuleScriptPath.Text.Trim()
                    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw 'Select an existing .ps1 detection script.' }
                    $ruleArgs.ScriptContent = Read-IwaScriptFile -Path $scriptPath
                    $ruleArgs.RunAs32Bit = [bool]$ui.RuleScriptRunAs32.IsChecked
                    $ruleArgs.EnforceSignatureCheck = [bool]$ui.RuleScriptSignature.IsChecked
                }
            }
            [void]$state.Rules.Add((New-IwaDetectionRule @ruleArgs))
            $state.KeepIntuneRules = $false
            $ui.RuleErrorText.Visibility = $collapsed
            & $refreshRules
        } catch {
            $ui.RuleErrorText.Text = $_.Exception.Message
            $ui.RuleErrorText.Visibility = $visible
        }
    })
    $ui.RemoveRuleButton.Add_Click({
        $index = $ui.RulesList.SelectedIndex
        if ($index -ge 0) { $state.Rules.RemoveAt($index); $state.KeepIntuneRules = $false; & $refreshRules }
    })

    foreach ($name in @('DisplayName', 'Publisher', 'DisplayVersion', 'Description', 'InstallCommandLine', 'UninstallCommandLine', 'MaxRunTimeInMinutes', 'PackagePath')) {
        $ui[$name].Add_TextChanged({ & $validate })
    }
    foreach ($name in @('ArchX64', 'ArchX86', 'ArchArm64')) {
        $ui[$name].Add_Click({ & $validate })
    }
    $ui.UploadContent.Add_Click({ & $applyPackageVersion; & $validate })

    $ui.UploadButton.Add_Click({
        $package = if ($ui.UploadContent.IsChecked) { $state.Package } else { $null }
        $body = New-IwaWin32AppBody -Spec (& $getForm) -Package $package -ForUpdate:([bool]$state.AppId)
        & $startTask $state.AppId $body $package
    })
    $ui.RetryUploadButton.Add_Click({
        # Without the app the failed create made, a retry would create a second app.
        if (-not $state.AppId) { $ui.RetryUploadButton.Visibility = $collapsed; return }
        if (-not $state.Package) { & $showStatus 'error' 'Select a valid .intunewin package first.'; return }
        # Same checks as Upload: the form is sent too.
        & $validate
        if (-not $ui.UploadButton.IsEnabled) { return }
        # Send the current form too, so edits made after the failure are not lost.
        $body = New-IwaWin32AppBody -Spec (& $getForm) -Package $state.Package -ForUpdate
        & $startTask $state.AppId $body $state.Package
    })
    $ui.OpenInIntune.Add_Click({ if ($state.AppId) { Start-Process (Get-IwaIntunePortalUrl -AppId $state.AppId) } })
    # The result panel stays open after "Open in Intune", so the user can still close it and go on.
    $ui.DoneOpenIntune.Add_Click({ if ($state.AppId) { Start-Process (Get-IwaIntunePortalUrl -AppId $state.AppId) } })
    $ui.DoneBack.Add_Click({ $ui.DoneOverlay.Visibility = $collapsed })

    # --- Connection settings: Microsoft's app or a custom app registration (#30) --------------------
    $showConnection = {
        if ($state.Busy -or $state.Waiting) { return }
        # After an invalid config.json, show what it holds, so the user sees what to fix.
        $ui.ConnectionClientId.Text = if ($state.ConfigWarning) { $state.ConfigClientId } else { $state.ClientId }
        $ui.ConnectionTenantId.Text = if ($state.ConfigWarning) { $state.ConfigTenantId } else { $state.TenantId }
        $ui.ConnectionError.Visibility = $collapsed
        $ui.ConnectionOverlay.Visibility = $visible
        $null = $ui.ConnectionClientId.Focus()
    }
    $hideConnection = { $ui.ConnectionOverlay.Visibility = $collapsed }
    $saveConnection = {
        $problem = Test-IwaConnectionSetting -ClientId $ui.ConnectionClientId.Text -TenantId $ui.ConnectionTenantId.Text
        if ($problem) {
            $ui.ConnectionError.Text = $problem
            $ui.ConnectionError.Visibility = $visible
            return
        }
        $canonical = ConvertTo-IwaConnectionSetting -ClientId $ui.ConnectionClientId.Text -TenantId $ui.ConnectionTenantId.Text
        $clientId = $canonical.ClientId
        $tenantId = $canonical.TenantId
        # Saving over an invalid config.json is a change even when the values in use (none) stay the same.
        $useApp = [bool]$clientId
        $changed = ($clientId -ne $state.ClientId) -or ($tenantId -ne $state.TenantId) -or ($useApp -ne $state.UseAppRegistration) -or [bool]$state.ConfigWarning
        $appChanged = ($useApp -ne $state.UseAppRegistration) -or ($useApp -and (($clientId -ne $state.ClientId) -or ($tenantId -ne $state.TenantId)))
        $state.ConfigWarning = $null
        $state.ClientId = $clientId
        $state.TenantId = $tenantId
        $state.UseAppRegistration = $useApp
        & $hideConnection
        if (-not $changed) { return }
        # A session opened with the other app must not be reused: sign out, the next sign-in uses the new one.
        if ($state.Account -and $appChanged) { Disconnect-IwaIntune }
        # $saveConfig belongs to Show-IntuneWinAppUtilGUI, which dot-sources this function.
        $saveError = $null
        try { & $saveConfig } catch { $saveError = $_.Exception.Message; Write-IwaDebugLog "Saving config.json failed: $saveError" }
        if ($state.Activated) { & $refreshAccount } else { $ui.GraphStatusText.Visibility = $collapsed; & $renderAccountBlock }
        $who = if ($useApp) { 'your app registration' } else { 'Microsoft''s app' }
        if ($saveError) { & $showStatus 'error' "The next sign-in uses $who, but the setting could not be saved for the next start: $saveError" }
        else { & $showStatus 'success' "Connection settings saved: sign in to use $who." }
    }
    # Switch method: the app registration values stay saved; a session of the other app is signed out.
    $selectMethod = {
        param([bool]$UseApp)
        if ($state.Busy -or $state.Waiting) { return }
        # Choosing a method also settles a warning about config.json (it is rewritten below).
        if ($UseApp -eq $state.UseAppRegistration -and -not $state.ConfigWarning) { return }
        $state.ConfigWarning = $null
        $state.UseAppRegistration = $UseApp
        if ($state.Account) { Disconnect-IwaIntune }
        $saveError = $null
        try { & $saveConfig } catch { $saveError = $_.Exception.Message; Write-IwaDebugLog "Saving config.json failed: $saveError" }
        & $refreshAccount
        $who = if ($UseApp) { 'your app registration (alpha)' } else { 'your Microsoft account' }
        if ($saveError) { & $showStatus 'error' "The next sign-in uses $who, but the choice could not be saved for the next start: $saveError" }
        else { & $showStatus 'success' "Sign in to continue with $who." }
    }
    $newMenuHeader = {
        param([string]$Title, [string]$Detail, [bool]$Alpha)
        $panel = New-Object System.Windows.Controls.StackPanel
        $titleRow = New-Object System.Windows.Controls.StackPanel
        $titleRow.Orientation = 'Horizontal'
        $titleText = New-Object System.Windows.Controls.TextBlock
        $titleText.Text = $Title; $titleText.FontWeight = 'SemiBold'
        [void]$titleRow.Children.Add($titleText)
        if ($Alpha) {
            $badge = New-Object System.Windows.Controls.Border
            $badge.Margin = '6,0,0,0'; $badge.Padding = '6,0'; $badge.CornerRadius = 8; $badge.BorderThickness = 1
            $badge.Background = & $brush '#FFF4E5'; $badge.BorderBrush = & $brush '#F5B060'
            $badgeText = New-Object System.Windows.Controls.TextBlock
            $badgeText.Text = 'ALPHA'; $badgeText.FontSize = 10; $badgeText.FontWeight = 'Bold'; $badgeText.Foreground = & $brush '#9A4A00'
            $badge.Child = $badgeText
            [void]$titleRow.Children.Add($badge)
        }
        [void]$panel.Children.Add($titleRow)
        $detailText = New-Object System.Windows.Controls.TextBlock
        $detailText.Text = $Detail; $detailText.FontSize = 11; $detailText.Foreground = & $brush '#667085'
        [void]$panel.Children.Add($detailText)
        $panel
    }
    $signInMenu = New-Object System.Windows.Controls.ContextMenu
    $menuMicrosoft = New-Object System.Windows.Controls.MenuItem
    $menuMicrosoft.Header = & $newMenuHeader 'Microsoft account' 'Recommended: Microsoft Graph Command Line Tools' $false
    $menuMicrosoft.IsCheckable = $true
    [System.Windows.Automation.AutomationProperties]::SetName($menuMicrosoft, 'Sign in with your Microsoft account (recommended)')
    $menuAppRegistration = New-Object System.Windows.Controls.MenuItem
    $menuAppRegistration.Header = & $newMenuHeader 'App registration' 'Your own Client ID and Tenant ID' $true
    $menuAppRegistration.IsCheckable = $true
    [System.Windows.Automation.AutomationProperties]::SetName($menuAppRegistration, 'Sign in with an app registration (alpha)')
    $menuAppSettings = New-Object System.Windows.Controls.MenuItem
    $menuAppSettings.Header = 'App registration settings...'
    [void]$signInMenu.Items.Add($menuMicrosoft)
    [void]$signInMenu.Items.Add($menuAppRegistration)
    [void]$signInMenu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$signInMenu.Items.Add($menuAppSettings)
    $menuMicrosoft.Add_Click({ & $selectMethod $false })
    # Without saved values there is nothing to switch to yet: the settings panel asks for them.
    $menuAppRegistration.Add_Click({ if ($state.ClientId) { & $selectMethod $true } else { & $showConnection } })
    $menuAppSettings.Add_Click({ & $showConnection })
    $ui.SignInMenuButton.Add_Click({
        if ($state.Busy -or $state.Waiting) { return }
        $menuMicrosoft.IsChecked = -not $state.UseAppRegistration
        $menuAppRegistration.IsChecked = [bool]$state.UseAppRegistration
        $signInMenu.PlacementTarget = $ui.SignInMenuButton
        $signInMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
        $signInMenu.IsOpen = $true
    })
    $ui.ConnectionSave.Add_Click({ & $saveConnection })
    $ui.ConnectionCancel.Add_Click({ & $hideConnection })
    $ui.ConnectionUseMicrosoft.Add_Click({
        & $hideConnection
        & $selectMethod $false
    })

    # --- Used by the main window ------------------------------------------------------------------
    # The Graph module check and the sign-in state wait for the tab: packaging never needs them.
    # From config.json, before the tab is first shown.
    $iwaSetConnection = {
        param([string]$ClientId, [string]$TenantId, [string]$Method)
        $problem = Test-IwaConnectionSetting -ClientId $ClientId -TenantId $TenantId
        if ($problem) {
            # Hand-edited config.json: say so on the tab instead of dropping the values without a word.
            Write-IwaDebugLog "Ignoring the app registration in config.json: $problem"
            $state.ConfigClientId = "$ClientId"; $state.ConfigTenantId = "$TenantId"
            $state.ConfigWarning = "The app registration in config.json was ignored: $problem Open Connection settings to fix it; until then Microsoft's app is used."
            $ui.GraphStatusText.Text = $state.ConfigWarning
            $ui.GraphStatusText.Visibility = $visible
            return
        }
        $canonical = ConvertTo-IwaConnectionSetting -ClientId $ClientId -TenantId $TenantId
        $state.ClientId = $canonical.ClientId; $state.TenantId = $canonical.TenantId
        # No method (configs before it existed) with a Client ID: the app registration, as before.
        if ($Method -and $Method -notin @('Microsoft', 'AppRegistration')) {
            Write-IwaDebugLog "Unknown IntuneSignInMethod '$Method' in config.json: using the Microsoft account."
            $state.ConfigWarning = "The sign-in method '$Method' in config.json is not known: your Microsoft account is used. Choose the method from the arrow next to Sign in."
            $ui.GraphStatusText.Text = $state.ConfigWarning
            $ui.GraphStatusText.Visibility = $visible
            $Method = 'Microsoft'
        }
        $state.UseAppRegistration = [bool]$state.ClientId -and $Method -ne 'Microsoft'
        & $renderAccountBlock
    }
    $iwaActivate = {
        if ($state.Activated) { return }
        $state.Activated = $true
        & $refreshAccount
    }
    $iwaOpenPackage = {
        param([string]$PackagePath, [string]$DisplayVersion, [string]$DisplayName, [string]$Publisher)
        if ($state.Busy) { return }
        $state.DisplayVersion = $DisplayVersion; $state.DisplayName = $DisplayName; $state.Publisher = $Publisher
        & $hideStatus
        $ui.DoneOverlay.Visibility = $collapsed
        # A package just built starts as a new app: never update the app picked or created before
        # (after a create the tab stays on that app). To update one, choose Update existing and search.
        if ($ui.ModeNew.IsChecked) {
            $state.AppId = $null
            $ui.OpenInIntune.IsEnabled = $false
        } else {
            $ui.ModeNew.IsChecked = $true
        }
        & $loadPackage $PackagePath
    }
    $iwaUploadRunning = { [bool]($state.Task -and -not $state.Task.Handle.IsCompleted) }
    # On close: an upload that ended after the last timer tick still holds its runspace.
    $iwaReleaseFinishedUpload = {
        if (-not $state.Task -or -not $state.Task.Handle.IsCompleted) { return }
        $timer.Stop()
        try { $null = $state.Task.PowerShell.EndInvoke($state.Task.Handle) } catch { }
        $state.Task.PowerShell.Dispose()
        $state.Task = $null
    }
    # BeginStop: Stop() would block the UI thread until the current block upload ends.
    $iwaStopUpload = {
        if (-not $state.Task) { return }
        $timer.Stop()
        try { $null = $state.Task.PowerShell.BeginStop($null, $null) } catch { }
        $state.Task = $null
    }

    $iwaHideConnection = $hideConnection
    $iwaSaveConnection = $saveConnection

    # --- Start -------------------------------------------------------------------------------
    & $renderAccountBlock
    & $applyMode
    & $loadPackage ''
}
