BeforeAll {
    $moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    . (Join-Path $moduleRoot 'Private\IWAPG-Hlp-IntuneWindow.ps1')
}

Describe 'Main window XAML with the Intune tab' {
    It 'injects the Intune tab into UI.xaml' {
        $xaml = Get-IwaMainWindowXaml -ModuleRoot $moduleRoot
        $xaml | Should -Not -Match 'INTUNE_PANEL -->'
        $xaml | Should -Match 'Name="IntunePanel"'
        { [xml]$xaml } | Should -Not -Throw
    }

    It 'defines every control the window code looks up' {
        [xml]$doc = Get-IwaMainWindowXaml -ModuleRoot $moduleRoot
        $names = @($doc.SelectNodes('//*[@Name]') | ForEach-Object { $_.GetAttribute('Name') })
        foreach ($name in Get-IwaIntuneWindowControlName) { $names | Should -Contain $name }
    }

    It 'only references resources that the window defines' {
        $xaml = Get-IwaMainWindowXaml -ModuleRoot $moduleRoot
        $keys = @([regex]::Matches($xaml, 'x:Key="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
        foreach ($ref in @([regex]::Matches($xaml, '\{StaticResource (\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
            $keys | Should -Contain $ref
        }
    }

    It 'parses as a WPF window with every named control of the tab' {
        $exe = (Get-Process -Id $PID).Path
        $helper = Join-Path $moduleRoot 'Private\IWAPG-Hlp-IntuneWindow.ps1'
        $cmd = "Add-Type -AssemblyName PresentationFramework; . '$helper'; `$w = [Windows.Markup.XamlReader]::Parse((Get-IwaMainWindowXaml -ModuleRoot '$moduleRoot')); @(Get-IwaIntuneWindowControlName | Where-Object { -not `$w.FindName(`$_) }).Count"
        $output = & $exe -NoProfile -NonInteractive -STA -Command $cmd 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        [int]($output | Select-Object -Last 1) | Should -Be 0 -Because ($output | Out-String)
    }

    It 'states the v1 limitations' {
        $script:IwaV1Limitations | Should -Be 'Not handled here yet: assignments, icon, supersedence, dependencies, custom return codes (Intune defaults are used). Use "Open in Intune" to set them in the portal.'
    }
}
