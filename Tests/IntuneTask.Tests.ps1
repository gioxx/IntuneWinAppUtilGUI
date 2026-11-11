BeforeAll {
    $moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    . (Join-Path $moduleRoot 'Private\IWAPG-Hlp-IntuneWindow.ps1')

    # Runs the background task script for real (synchronously) against stub helpers that only write a log.
    function Invoke-TaskScript {
        param($State, $Body, $Package, [switch]$PublishThrows)
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $log = Join-Path $root 'calls.log'
        New-Item -ItemType Directory -Path (Join-Path $root 'Private') -Force | Out-Null
        New-Item -ItemType File -Path $log | Out-Null
        $throwLine = if ($PublishThrows) { "throw 'publish boom'" } else { '' }
        Set-Content -LiteralPath (Join-Path $root 'Private\IWAPG-Hlp-IntunePackage.ps1') -Value @"
function Expand-IwaIntuneWinContent {
    param(`$Package, `$Destination)
    New-Item -ItemType Directory -Path `$Destination -Force | Out-Null
    Add-Content -LiteralPath '$log' -Value "EXPAND `$Destination"
    'content.bin'
}
"@
        Set-Content -LiteralPath (Join-Path $root 'Private\IWAPG-Hlp-IntuneGraph.ps1') -Value @"
`$script:IwaGraphAppsUri = 'https://graph.example/apps'
function Invoke-IwaGraph {
    param(`$Method, `$Uri, `$Body)
    Add-Content -LiteralPath '$log' -Value "`$Method `$Uri"
    [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000001' }
}
function Publish-IwaWin32AppContent {
    param(`$AppId, `$Package, `$ContentFile, `$AppBody, `$OnProgress)
    Add-Content -LiteralPath '$log' -Value ('PUBLISH appBody=' + `$(if (`$AppBody) { 'yes' } else { 'no' }))
    $throwLine
}
function Get-IwaGraphErrorMessage { param(`$ErrorRecord) "graph: `$(`$ErrorRecord.Exception.Message)" }
"@
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:IwaIntuneTaskScript.ToString()).AddArgument($State).AddArgument($root).AddArgument($Body).AddArgument($Package)
        try { [void]$ps.Invoke() } finally { $ps.Dispose() }
        @(Get-Content -LiteralPath $log)
    }
    function New-TaskState {
        param($AppId, $Saved = $false)
        [hashtable]::Synchronized(@{ Step = ''; Percent = 0; AppId = $AppId; Saved = $Saved; Error = $null; Done = $false })
    }

    # The task imports Microsoft.Graph.Authentication; an empty stand-in module keeps CI machines without it working.
    $stubModules = Join-Path $TestDrive 'modules'
    New-Item -ItemType Directory -Path (Join-Path $stubModules 'Microsoft.Graph.Authentication') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stubModules 'Microsoft.Graph.Authentication\Microsoft.Graph.Authentication.psm1') -Value ''
    $oldModulePath = $env:PSModulePath
    $env:PSModulePath = $stubModules + [System.IO.Path]::PathSeparator + $env:PSModulePath
    $body = @{ displayName = 'Contoso Tool' }
    $package = [pscustomobject]@{ Path = 'C:\Out\contoso.intunewin' }
}

AfterAll { $env:PSModulePath = $oldModulePath }

Describe 'Intune background task' {
    It 'creates the app, then uploads the content without an update body (New)' {
        $state = New-TaskState
        $log = Invoke-TaskScript -State $state -Body $body -Package $package
        $calls = @($log | Where-Object { $_ -notlike 'EXPAND*' })
        $calls | Should -Be @('POST https://graph.example/apps', 'PUBLISH appBody=no')
        $state.AppId | Should -Be '00000000-0000-0000-0000-000000000001'
        $state.Saved | Should -BeTrue
        $state.Done | Should -BeTrue
    }
    It 'leaves the settings to the commit PATCH when updating with a package' {
        $state = New-TaskState -AppId '00000000-0000-0000-0000-000000000002'
        $log = Invoke-TaskScript -State $state -Body $body -Package $package
        @($log | Where-Object { $_ -like 'PATCH*' }).Count | Should -Be 0
        $log | Should -Contain 'PUBLISH appBody=yes'
        $state.Saved | Should -BeFalse
    }
    It 'sends one PATCH and no content when updating settings only' {
        $state = New-TaskState -AppId '00000000-0000-0000-0000-000000000002'
        $log = Invoke-TaskScript -State $state -Body $body -Package $null
        @($log | Where-Object { $_ -like 'PATCH*' }).Count | Should -Be 1
        @($log | Where-Object { $_ -like 'PUBLISH*' }).Count | Should -Be 0
        $state.Saved | Should -BeTrue
    }
    It 'retries the upload without POST or PATCH' {
        $state = New-TaskState -AppId '00000000-0000-0000-0000-000000000001' -Saved $true
        $log = Invoke-TaskScript -State $state -Body $null -Package $package
        @($log | Where-Object { $_ -like 'POST*' -or $_ -like 'PATCH*' }).Count | Should -Be 0
        $log | Should -Contain 'PUBLISH appBody=no'
    }
    It 'reports the error and removes the temp folder when the upload throws' {
        $state = New-TaskState -AppId '00000000-0000-0000-0000-000000000001' -Saved $true
        $log = Invoke-TaskScript -State $state -Body $null -Package $package -PublishThrows
        $state.Error | Should -Be 'graph: publish boom'
        $state.Done | Should -BeFalse
        $expanded = ($log | Where-Object { $_ -like 'EXPAND *' } | Select-Object -First 1) -replace '^EXPAND ', ''
        $expanded | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $expanded | Should -BeFalse
    }
}
