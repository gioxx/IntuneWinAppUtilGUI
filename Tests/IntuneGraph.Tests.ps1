BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\IWAPG-Hlp-IntuneGraph.ps1')
    # CI has no Graph module: give Pester a command to mock.
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function script:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
    }
}

Describe 'Invoke-IwaGraph' {
    It 'sends the body as JSON' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ id = 'x' } }
        (Invoke-IwaGraph -Method POST -Uri 'https://graph.example/apps' -Body @{ a = 1 }).id | Should -Be 'x'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $ContentType -eq 'application/json' -and $OutputType -eq 'PSObject' -and ($Body | ConvertFrom-Json).a -eq 1
        }
    }
    It 'sends no body on GET' {
        Mock Invoke-MgGraphRequest { }
        Invoke-IwaGraph -Method GET -Uri 'https://graph.example/apps'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -ParameterFilter { $null -eq $Body }
    }
}

Describe 'Get-IwaGraphErrorMessage' {
    It 'extracts the Graph error code and message' {
        $exception = New-Object System.Exception 'Response status code 400. {"error":{"code":"BadRequest","message":"Invalid displayName"}} trailing'
        $record = New-Object System.Management.Automation.ErrorRecord $exception, 'id', 'NotSpecified', $null
        Get-IwaGraphErrorMessage -ErrorRecord $record | Should -Be 'BadRequest: Invalid displayName'
    }
    It 'prefers ErrorDetails when present' {
        $record = New-Object System.Management.Automation.ErrorRecord (New-Object System.Exception 'generic'), 'id', 'NotSpecified', $null
        $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails '{"error":{"code":"Forbidden","message":"No access"}}'
        Get-IwaGraphErrorMessage -ErrorRecord $record | Should -Be 'Forbidden: No access'
    }
    It 'falls back to the exception message' {
        $record = New-Object System.Management.Automation.ErrorRecord (New-Object System.Exception 'Network down'), 'id', 'NotSpecified', $null
        Get-IwaGraphErrorMessage -ErrorRecord $record | Should -Be 'Network down'
    }
}

Describe 'Get-IwaWin32App' {
    It 'follows paging and filters by name' {
        Mock Invoke-IwaGraph {
            if ($Uri -like '*page2*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = '3'; displayName = 'Contoso Viewer' }) }
            }
            [pscustomobject]@{
                value = @([pscustomobject]@{ id = '1'; displayName = 'Fabrikam Tool' }, [pscustomobject]@{ id = '2'; displayName = 'Contoso Agent' })
                '@odata.nextLink' = 'https://graph.example/page2'
            }
        }
        $apps = @(Get-IwaWin32App -Search 'contoso')
        $apps.Count | Should -Be 2
        $apps[0].displayName | Should -Be 'Contoso Agent'
        $apps[1].displayName | Should -Be 'Contoso Viewer'
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Uri -like "*isof('microsoft.graph.win32LobApp')*" }
    }
    It 'returns every app with an empty search and handles an empty page' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ value = @() } }
        @(Get-IwaWin32App).Count | Should -Be 0
    }
    It 'reads one app by id' {
        Mock Invoke-IwaGraph { [pscustomobject]@{ id = 'abc' } }
        (Get-IwaWin32App -Id 'abc').id | Should -Be 'abc'
        Should -Invoke Invoke-IwaGraph -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/abc' }
    }
}

Describe 'Get-IwaIntunePortalUrl' {
    It 'links to the app page in the Intune admin center' {
        Get-IwaIntunePortalUrl -AppId '00000000-0000-0000-0000-000000000001' | Should -Be 'https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/00000000-0000-0000-0000-000000000001'
    }
}
