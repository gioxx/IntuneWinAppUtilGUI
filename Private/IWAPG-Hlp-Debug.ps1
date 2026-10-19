function Write-IwaDebugLog {
    <#
    .SYNOPSIS
    Appends a timestamped line to the debug log when debug logging is enabled.
    .DESCRIPTION
    Does nothing unless $script:IwaDebugLogPath is set (Show-IntuneWinAppUtilGUI -DebugLog).
    Never throws: logging must not break packaging.
    .PARAMETER Message
    Text to log; multi-line text is indented under the timestamp.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    if (-not $script:IwaDebugLogPath) { return }
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $text = ($Message -split "`r?`n") -join ("`r`n" + (' ' * 26))
        Add-Content -LiteralPath $script:IwaDebugLogPath -Value "$stamp  $text" -Encoding UTF8
    } catch { }
}

function Write-IwaDebugFileState {
    <#
    .SYNOPSIS
    Logs the files IntuneWinAppUtil left behind after a run, and which processes hold them open.
    .DESCRIPTION
    IntuneWinAppUtil works in a GUID-named folder under %TEMP% and removes it only when it succeeds.
    Lists those folders modified since the run started, plus the files in the given extra folders.
    No-op unless debug logging is enabled.
    .PARAMETER Since
    Start time of the packaging run.
    .PARAMETER Folder
    Extra folders to inspect (e.g. staging or output folder).
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [string[]]$Folder = @()
    )

    if (-not $script:IwaDebugLogPath) { return }

    $folders = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -and $_.LastWriteTime -ge $Since.AddSeconds(-2) -and (Test-Path (Join-Path $_.FullName 'IntuneWinPackage')) } |
        ForEach-Object FullName)
    $folders += @($Folder | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

    if ($folders.Count -eq 0) {
        Write-IwaDebugLog "No IntuneWinAppUtil temp folders found."
        return
    }

    foreach ($dir in $folders) {
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)
        Write-IwaDebugLog ("Folder '{0}': {1} file(s)" -f $dir, $files.Count)
        foreach ($file in $files) {
            $lockers = @(Get-FileLockingProcess -Path $file.FullName)
            $lockText = if ($lockers.Count) { 'held by: ' + ($lockers -join ', ') } else { 'not held' }
            Write-IwaDebugLog ("  {0}  {1:N0} bytes  {2}  {3}" -f $file.FullName, $file.Length, $file.LastWriteTime.ToString('HH:mm:ss.fff'), $lockText)
        }
    }
}

function Get-FileLockingProcess {
    <#
    .SYNOPSIS
    Returns the processes that currently hold the given files open, via the Windows Restart Manager.
    .PARAMETER Path
    One or more file paths.
    .OUTPUTS
    [string[]] "ProcessName (PID)" entries; empty when nothing holds the files or the query fails.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path
    )

    if (-not ('IwaRestartManager' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class IwaRestartManager {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static List<int> GetLockingProcessIds(string[] paths) {
        var result = new List<int>();
        uint handle;
        if (RmStartSession(out handle, 0, Guid.NewGuid().ToString()) != 0) { return result; }
        try {
            if (RmRegisterResources(handle, (uint)paths.Length, paths, 0, IntPtr.Zero, 0, null) != 0) { return result; }
            uint needed = 0, count = 0, reasons = 0;
            int rc = RmGetList(handle, out needed, ref count, null, ref reasons);
            if (rc == 234 && needed > 0) { // ERROR_MORE_DATA
                var infos = new RM_PROCESS_INFO[needed];
                count = needed;
                if (RmGetList(handle, out needed, ref count, infos, ref reasons) == 0) {
                    for (int i = 0; i < count; i++) { result.Add(infos[i].Process.dwProcessId); }
                }
            }
        } finally { RmEndSession(handle); }
        return result;
    }
}
'@
    }

    try {
        foreach ($processId in [IwaRestartManager]::GetLockingProcessIds([string[]]$Path)) {
            $name = try { (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { '?' }
            "$name ($processId)"
        }
    } catch { }
}
