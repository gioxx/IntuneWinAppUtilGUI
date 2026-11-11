# Test-IwaGraphSpike.ps1
# Manual check for the Publish to Intune window. Run from the repo root, in both shells:
#   powershell -NoProfile -STA -File .\Tools\Test-IwaGraphSpike.ps1
#   pwsh -NoProfile -STA -File .\Tools\Test-IwaGraphSpike.ps1
# 1. Connect-MgGraph works when called from a WPF button handler (STA thread, window open).
# 2. A second runspace in the same process can call Invoke-MgGraphRequest with that sign-in.
Add-Type -AssemblyName PresentationFramework
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Graph spike" Width="460" Height="220">
  <StackPanel Margin="12">
    <Button Name="Go" Content="Sign in and test" Height="32"/>
    <TextBlock Name="Out" Margin="0,10,0,0" TextWrapping="Wrap"/>
  </StackPanel>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$out = $window.FindName('Out')
$window.FindName('Go').Add_Click({
    try {
        Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All' -NoWelcome -ErrorAction Stop
        $out.Text = "1. Sign-in OK.`n"
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            $r = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=1&`$select=id" -OutputType PSObject -ErrorAction Stop
            "2. Runspace call OK ($(@($r.value).Count) app returned)."
        }.ToString())
        $result = $ps.Invoke()
        $out.Text += ($result | Out-String)
        if ($ps.HadErrors) { $out.Text += "2. Runspace call FAILED: $($ps.Streams.Error[0])" }
        $ps.Dispose()
    } catch {
        $out.Text += "FAILED: $($_.Exception.Message)"
    }
})
$window.ShowDialog() | Out-Null
