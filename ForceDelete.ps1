<#
.SYNOPSIS
    FORCE DELETE PRO - diagnose-first Windows file and folder removal utility.

.DESCRIPTION
    Interactive console tool. It diagnoses why a file or folder cannot be deleted,
    optionally stops a confirmed matching Windows service (separate confirmation),
    optionally repairs ownership/permissions on failed items (separate confirmation),
    then deletes with literal paths, bounded retries and an honest final report.

.PARAMETER Path
    Optional target path. If omitted you are asked for it.
.PARAMETER LogDir
    Optional log directory. Default: %LOCALAPPDATA%\ForceDeletePro\logs
.PARAMETER Elevated
    Internal flag: set when this instance was relaunched as administrator.
.PARAMETER NoElevate
    Do not offer to relaunch as administrator.
.PARAMETER CreateFixtures
    Create disposable test folders under %TEMP%\ForceDelete Pro Test and exit.
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$LogDir = '',
    [switch]$Elevated,
    [switch]$NoElevate,
    [switch]$CreateFixtures
)

$ErrorActionPreference = 'Continue'

$script:AppName    = 'FORCE DELETE PRO'
$script:AppVersion = '1.0.0'
$script:ScriptRoot = Split-Path -Parent $PSCommandPath
$script:LogWriter  = $null
$script:LogPath    = $null
$script:RmReady    = $false
$script:S          = $null
$script:AdminSid   = 'S-1-5-32-544'

# ---------------------------------------------------------------------------
# Restart Manager helper (Windows-supported API for "which process uses this file")
# ---------------------------------------------------------------------------
$script:RmSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class RestartManagerHelper
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFileNames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    // Returns "PID|AppName|ServiceShortName" entries for processes using any of the files.
    public static List<string> GetLockers(string[] files)
    {
        List<string> result = new List<string>();
        uint handle;
        string key = Guid.NewGuid().ToString();
        int rc = RmStartSession(out handle, 0, key);
        if (rc != 0) { throw new Exception("RmStartSession failed with code " + rc); }
        try
        {
            rc = RmRegisterResources(handle, (uint)files.Length, files, 0, null, 0, null);
            if (rc != 0) { throw new Exception("RmRegisterResources failed with code " + rc); }

            uint needed = 0, count = 0, reasons = 0;
            RM_PROCESS_INFO[] info = null;
            rc = RmGetList(handle, out needed, ref count, info, ref reasons);
            int tries = 0;
            while (rc == 234 && tries < 5)
            {
                info = new RM_PROCESS_INFO[needed];
                count = needed;
                rc = RmGetList(handle, out needed, ref count, info, ref reasons);
                tries++;
            }
            if (rc != 0) { throw new Exception("RmGetList failed with code " + rc); }
            for (int i = 0; i < count; i++)
            {
                result.Add(info[i].Process.dwProcessId + "|" + info[i].strAppName + "|" + info[i].strServiceShortName);
            }
        }
        finally
        {
            RmEndSession(handle);
        }
        return result;
    }
}
'@

# ---------------------------------------------------------------------------
# Console + logging helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Level, [string]$Text)
    if ($script:LogWriter) {
        try {
            $script:LogWriter.WriteLine(('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Text))
        } catch { }
    }
}

function Out-Msg {
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'PLAIN')][string]$Level,
        [string]$Text
    )
    $color = 'Gray'
    $prefix = '[INFO] '
    switch ($Level) {
        'OK'    { $color = 'Green';  $prefix = '[ OK ] ' }
        'WARN'  { $color = 'Yellow'; $prefix = '[WARN] ' }
        'ERROR' { $color = 'Red';    $prefix = '[FAIL] ' }
        'STEP'  { $color = 'Cyan';   $prefix = '' }
        'PLAIN' { $color = 'Gray';   $prefix = '       ' }
        default { }
    }
    Write-Host ($prefix + $Text) -ForegroundColor $color
    Write-Log $Level $Text
}

function Out-Finding {
    param(
        [ValidateSet('Confirmed', 'Possible', 'Info')][string]$Kind,
        [string]$Text
    )
    $color = 'Gray'
    if ($Kind -eq 'Confirmed') { $color = 'White' }
    if ($Kind -eq 'Possible')  { $color = 'Yellow' }
    $label = '[' + $Kind.ToUpper() + ']'
    Write-Host ('  {0,-11} {1}' -f $label, $Text) -ForegroundColor $color
    Write-Log 'DIAG' ($label + ' ' + $Text)
}

function Read-Input {
    param([string]$Prompt = 'Your answer')
    Write-Host ''
    $v = Read-Host $Prompt
    if ($null -eq $v) { $v = '' }
    $v = $v.Trim()
    Write-Log 'INPUT' ('[{0}] {1}' -f $Prompt, $v)
    return $v
}

function Show-Banner {
    try { Clear-Host } catch { }
    $line = '=' * 72
    Write-Host $line -ForegroundColor Cyan
    Write-Host ('  {0}   v{1}' -f $script:AppName, $script:AppVersion) -ForegroundColor White
    Write-Host '  Advanced Windows File & Folder Removal Utility' -ForegroundColor Gray
    Write-Host '  Diagnose first. Delete only what you explicitly confirm.' -ForegroundColor Gray
    Write-Host $line -ForegroundColor Cyan
    if (Test-IsAdmin) {
        Write-Host '  Privileges: Administrator' -ForegroundColor Green
    } else {
        Write-Host '  Privileges: standard user (permission repair and service control will not work)' -ForegroundColor Yellow
    }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

function Get-Unwrapped {
    param($Exception)
    $ex = $Exception
    while ($ex -and $ex.InnerException -and ($ex -is [System.Management.Automation.MethodInvocationException] -or $ex -is [System.Reflection.TargetInvocationException])) {
        $ex = $ex.InnerException
    }
    return $ex
}

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Returns $true when a new elevated instance was started and this one should exit.
function Request-Elevation {
    if ($NoElevate -or $Elevated -or (Test-IsAdmin)) { return $false }
    Write-Host ''
    Write-Host 'This tool works best as Administrator (ownership repair, service control, lock diagnostics).' -ForegroundColor Yellow
    $a = Read-Host 'Relaunch as Administrator now? (Y/N)'
    if ($a -and $a.Trim() -match '^(y|yes)$') {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Elevated')
        if ($Path) { $argList += @('-Path', ('"{0}"' -f $Path.TrimEnd('\'))) }
        if ($LogDir) { $argList += @('-LogDir', ('"{0}"' -f $LogDir.TrimEnd('\'))) }
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop
            return $true
        } catch {
            Write-Host ('Elevation was cancelled or failed: ' + $_.Exception.Message) -ForegroundColor Yellow
            Write-Host 'Continuing without administrator rights.' -ForegroundColor Yellow
            return $false
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Get-LogDirectory {
    $candidates = @()
    if ($LogDir) { $candidates += $LogDir }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'ForceDeletePro\logs') }
    if ($env:TEMP) { $candidates += (Join-Path $env:TEMP 'ForceDeletePro\logs') }
    foreach ($c in $candidates) {
        try {
            [void][System.IO.Directory]::CreateDirectory($c)
            $probe = Join-Path $c ('.w' + [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($probe, 'x')
            [System.IO.File]::Delete($probe)
            return $c
        } catch { }
    }
    return $null
}

function Open-Log {
    $dir = Get-LogDirectory
    if (-not $dir) {
        Write-Host 'WARNING: no writable log directory found; logging is disabled for this operation.' -ForegroundColor Yellow
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file = Join-Path $dir ('ForceDelete_{0}.log' -f $stamp)
    $n = 1
    while (Test-Path -LiteralPath $file) {
        $file = Join-Path $dir ('ForceDelete_{0}_{1}.log' -f $stamp, $n)
        $n++
    }
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        $script:LogWriter = New-Object System.IO.StreamWriter($file, $false, $enc)
        $script:LogWriter.AutoFlush = $true
        $script:LogPath = $file
    } catch {
        Write-Host ('WARNING: cannot open log file: ' + $_.Exception.Message) -ForegroundColor Yellow
        $script:LogWriter = $null
        $script:LogPath = $null
    }
}

function Close-Log {
    param([string]$Status)
    if ($script:LogWriter) {
        Write-Log 'INFO' ('Completed at: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Write-Log 'INFO' ('FINAL STATUS: ' + $Status)
        try { $script:LogWriter.Flush(); $script:LogWriter.Dispose() } catch { }
        $script:LogWriter = $null
    }
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
function ConvertTo-ExtPath {
    param([string]$P)
    if ($P.StartsWith('\\?\')) { return $P }
    if ($P.StartsWith('\\')) { return ('\\?\UNC\' + $P.Substring(2)) }
    return ('\\?\' + $P)
}

function Test-PathUnder {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrEmpty($Child) -or [string]::IsNullOrEmpty($Parent)) { return $false }
    $c = $Child.TrimEnd('\')
    $p = $Parent.TrimEnd('\')
    if ($c.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith(($p + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ParentPath {
    param([string]$P)
    $t = $P.TrimEnd('\')
    if ($t -match '^[A-Za-z]:\\[^\\]*$') { return $t.Substring(0, 3) }
    $i = $t.LastIndexOf('\')
    if ($i -le 0) { return $null }
    return $t.Substring(0, $i)
}

function Resolve-TargetPath {
    param([string]$Raw)
    $r = [pscustomobject]@{ Ok = $false; Full = ''; Error = '' }
    $p = $Raw.Trim()
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { $p = $p.Substring(1, $p.Length - 2).Trim() }
    elseif ($p.Length -ge 2 -and $p.StartsWith("'") -and $p.EndsWith("'")) { $p = $p.Substring(1, $p.Length - 2).Trim() }
    $p = $p.Trim('"')
    if ($p.StartsWith('\\?\UNC\')) { $p = '\\' + $p.Substring(8) }
    elseif ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    if ($p.Length -eq 0) { $r.Error = 'No path was entered.'; return $r }
    if ($p -match '[\*\?<>\|"]') { $r.Error = 'The path contains wildcard or invalid characters (* ? < > | ").'; return $r }
    if (-not (($p -match '^[A-Za-z]:\\') -or ($p -match '^\\\\[^\\]+\\[^\\]+'))) {
        $r.Error = 'Please enter a full path, for example D:\folder\file.txt or \\server\share\folder.'
        return $r
    }
    if ($p.Substring(2).Contains(':')) { $r.Error = 'Alternate data stream or invalid colon in path.'; return $r }
    try {
        $full = [System.IO.Path]::GetFullPath($p)
    } catch {
        if ($p -match '(^|\\)\.\.?(\\|$)') { $r.Error = 'The path could not be normalised: ' + $_.Exception.Message; return $r }
        $full = $p
    }
    if (-not ($full -match '^[A-Za-z]:\\$')) { $full = $full.TrimEnd('\') }
    $r.Ok = $true
    $r.Full = $full
    return $r
}

function Test-TargetExists {
    $ext = ConvertTo-ExtPath $script:S.Target
    return ([System.IO.File]::Exists($ext) -or [System.IO.Directory]::Exists($ext))
}

function Test-ReparseFlag {
    param([string]$P)
    try { return (([int][System.IO.File]::GetAttributes((ConvertTo-ExtPath $P)) -band 1024) -ne 0) } catch { return $false }
}

# True for symlinks/junctions. Unsure -> $true (safe: we do not descend into it).
function Test-IsLinkLike {
    param([string]$P)
    try {
        $it = Get-Item -LiteralPath $P -Force -ErrorAction Stop
        return (-not [string]::IsNullOrEmpty([string]$it.LinkType))
    } catch { return $true }
}

# Returns a reason string if the target must never be deleted by this tool, else $null.
function Get-ProtectedReason {
    param([string]$Full)
    $norm = $Full.TrimEnd('\')
    if ($Full -match '^[A-Za-z]:\\?$') { return 'This is a drive root.' }
    if ($Full -match '^\\\\[^\\]+\\[^\\]+\\?$') { return 'This is the root of a network share.' }
    if ($Full -match '^[A-Za-z]:\\(System Volume Information|\$Recycle\.Bin)(\\|$)') { return 'This is a protected Windows system area.' }

    $trees = New-Object 'System.Collections.Generic.List[string]'
    $exact = New-Object 'System.Collections.Generic.List[string]'
    $sysDrive = $env:SystemDrive
    if ($env:SystemRoot) { $trees.Add($env:SystemRoot) }
    if ($sysDrive) {
        foreach ($n in @('Recovery', 'Boot', 'EFI')) { $trees.Add(($sysDrive + '\' + $n)) }
        $exact.Add(($sysDrive + '\Users'))
    }
    if ($script:ScriptRoot) { $trees.Add($script:ScriptRoot) }
    foreach ($v in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData, $env:ALLUSERSPROFILE, $env:PUBLIC, $env:USERPROFILE)) {
        if ($v) { $exact.Add($v) }
    }
    if ($env:USERPROFILE) {
        foreach ($n in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'AppData', 'AppData\Local', 'AppData\Roaming')) {
            $exact.Add((Join-Path $env:USERPROFILE $n))
        }
    }
    foreach ($t in $trees) {
        if ((Test-PathUnder $norm $t) -or (Test-PathUnder $t $norm)) {
            if ($script:ScriptRoot -and $t -eq $script:ScriptRoot) { return 'This is (or contains) the folder of this program.' }
            return ('This is, contains or lies inside a critical Windows location (' + $t + ').')
        }
    }
    foreach ($e in $exact) {
        if ((Test-PathUnder $e $norm)) { return ('This is, or contains, a critical system or user-profile folder (' + $e + ').') }
    }
    return $null
}

function Get-CautionNote {
    param([string]$Full)
    foreach ($v in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE)) {
        if ($v -and (Test-PathUnder $Full $v)) { return ('Caution: the target is inside ' + $v + '. Make sure it belongs to software you intend to remove.') }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Inventory (literal paths, never follows links)
# ---------------------------------------------------------------------------
function Get-TargetInventory {
    param([string]$Root)
    $inv = [pscustomobject]@{
        Files      = New-Object 'System.Collections.Generic.List[string]'
        Dirs       = New-Object 'System.Collections.Generic.List[string]'
        Links      = New-Object 'System.Collections.Generic.List[string]'
        Unreadable = New-Object 'System.Collections.Generic.List[string]'
        Errors     = New-Object 'System.Collections.Generic.List[string]'
        Bytes      = [long]0
        CntReadOnly = 0
        CntHidden   = 0
        CntSystem   = 0
    }
    $rootExt = ConvertTo-ExtPath $Root
    if ([System.IO.File]::Exists($rootExt)) {
        $a = [int][System.IO.File]::GetAttributes($rootExt)
        $inv.Files.Add($Root)
        if (($a -band 1) -ne 0) { $inv.CntReadOnly++ }
        if (($a -band 2) -ne 0) { $inv.CntHidden++ }
        if (($a -band 4) -ne 0) { $inv.CntSystem++ }
        if (($a -band 1024) -ne 0) { $inv.Links.Add($Root) }
        try { $inv.Bytes += (New-Object -TypeName System.IO.FileInfo -ArgumentList $rootExt).Length } catch { }
        return $inv
    }
    if (-not [System.IO.Directory]::Exists($rootExt)) { return $inv }

    $ra = [int][System.IO.File]::GetAttributes($rootExt)
    if ((($ra -band 1024) -ne 0) -and (Test-IsLinkLike $Root)) {
        $inv.Dirs.Add($Root)
        $inv.Links.Add($Root)
        return $inv
    }

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $inv.Dirs.Add($d)
        $children = $null
        try {
            $di = New-Object -TypeName System.IO.DirectoryInfo -ArgumentList (ConvertTo-ExtPath $d)
            $children = $di.GetFileSystemInfos()
        } catch {
            $ex = Get-Unwrapped $_.Exception
            $inv.Unreadable.Add($d)
            $inv.Errors.Add(('{0} -> {1}' -f $d, $ex.Message))
            continue
        }
        foreach ($c in $children) {
            $full = $d.TrimEnd('\') + '\' + $c.Name
            $a = [int]$c.Attributes
            if (($a -band 1) -ne 0) { $inv.CntReadOnly++ }
            if (($a -band 2) -ne 0) { $inv.CntHidden++ }
            if (($a -band 4) -ne 0) { $inv.CntSystem++ }
            if (($a -band 16) -ne 0) {
                if ((($a -band 1024) -ne 0) -and (Test-IsLinkLike $full)) {
                    $inv.Dirs.Add($full)
                    $inv.Links.Add($full)
                } else {
                    $stack.Push($full)
                }
            } else {
                $inv.Files.Add($full)
                if (($a -band 1024) -ne 0) { $inv.Links.Add($full) }
                try { $inv.Bytes += $c.Length } catch { }
            }
        }
    }
    return $inv
}

# ---------------------------------------------------------------------------
# ACL / access assessment
# ---------------------------------------------------------------------------
function Get-MySids {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add($id.User.Value)
    foreach ($g in $id.Groups) { $list.Add($g.Value) }
    return $list.ToArray()
}

function Resolve-SidName {
    param([string]$Sid)
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value
    } catch { return $Sid }
}

function Get-AccessAssessment {
    param([string]$P)
    $r = [pscustomobject]@{
        Ok = $false; Owner = $null; OwnerSid = $null
        Deny = @(); CanDelete = $false; CanDeleteChild = $false
        AdminFull = $false; Error = $null
    }
    try {
        $acl = Get-Acl -LiteralPath $P -ErrorAction Stop
        $r.Owner = $acl.Owner
        try { $r.OwnerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        $mine = @(Get-MySids)
        $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            $rights = [long]$rule.FileSystemRights
            $isDel = ((($rights -band 0x10000) -ne 0) -or (($rights -band 0x10000000) -ne 0))
            $isDelChild = ((($rights -band 0x40) -ne 0) -or (($rights -band 0x10000000) -ne 0))
            if ($sid -eq $script:AdminSid -and $rule.AccessControlType -eq 'Allow' -and (($rights -band 0x1F01FF) -eq 0x1F01FF)) { $r.AdminFull = $true }
            if ($mine -notcontains $sid) { continue }
            if ($rule.AccessControlType -eq 'Deny') {
                if ($isDel -or $isDelChild) { $r.Deny += (Resolve-SidName $sid) }
            } else {
                if ($isDel) { $r.CanDelete = $true }
                if ($isDelChild) { $r.CanDeleteChild = $true }
            }
        }
        $r.Ok = $true
    } catch {
        $r.Error = (Get-Unwrapped $_.Exception).Message
    }
    return $r
}

# ---------------------------------------------------------------------------
# File-lock identification via Windows Restart Manager
# ---------------------------------------------------------------------------
function Initialize-RestartManager {
    if ($script:RmReady) { return }
    if (-not ('RestartManagerHelper' -as [type])) {
        try {
            Add-Type -TypeDefinition $script:RmSource -Language CSharp -ErrorAction Stop
        } catch {
            Write-Log 'WARN' ('Restart Manager helper could not be compiled: ' + $_.Exception.Message)
            return
        }
    }
    $script:RmReady = $true
}

# Returns object: Known (bool), Items (PID/Name/Service/Count), Errors (int)
function Get-FileLockers {
    param([string[]]$Files)
    $res = [pscustomobject]@{ Known = $false; Items = @(); Errors = 0 }
    Initialize-RestartManager
    if (-not $script:RmReady -or -not $Files -or $Files.Count -eq 0) { return $res }
    $found = @{}
    $okBatches = 0
    for ($i = 0; $i -lt $Files.Count; $i += 500) {
        $end = [Math]::Min($i + 499, $Files.Count - 1)
        $batch = [string[]]($Files[$i..$end])
        try {
            $list = [RestartManagerHelper]::GetLockers($batch)
            $okBatches++
            foreach ($entry in $list) {
                $parts = $entry.Split([char]'|')
                $lockPid = $parts[0]
                if ($found.ContainsKey($lockPid)) {
                    $found[$lockPid].Count++
                } else {
                    $svc = ''
                    if ($parts.Count -gt 2) { $svc = $parts[2] }
                    $found[$lockPid] = [pscustomobject]@{ ProcessId = [int]$lockPid; Name = $parts[1]; Service = $svc; Count = 1 }
                }
            }
        } catch {
            $res.Errors++
            Write-Log 'WARN' ('Restart Manager query failed: ' + (Get-Unwrapped $_.Exception).Message)
        }
    }
    $res.Known = ($okBatches -gt 0)
    $res.Items = @($found.Values)
    return $res
}

function Get-SecurityInfo {
    $info = [pscustomobject]@{ DefenderAvailable = $false; RealTime = $null; Cfa = $null; ThirdParty = @() }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $info.DefenderAvailable = $true
        $info.RealTime = $mp.RealTimeProtectionEnabled
    } catch { }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        if ($null -ne $pref.EnableControlledFolderAccess) { $info.Cfa = [int]$pref.EnableControlledFolderAccess }
    } catch { }
    try {
        $av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
        $info.ThirdParty = @($av | ForEach-Object { $_.displayName })
    } catch { }
    return $info
}

# ---------------------------------------------------------------------------
# Windows services
# ---------------------------------------------------------------------------
function Get-ExecutablePath {
    param([string]$CommandLine)
    $c = $CommandLine.Trim()
    if ($c.StartsWith('\??\')) { $c = $c.Substring(4) }
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 0) { return $c.Substring(1, $end - 1) }
    }
    $m = [regex]::Match($c, '^(.+?\.(?:exe|com|sys|dll|bat|cmd))(?:\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    $sp = $c.IndexOf(' ')
    if ($sp -gt 0) { return $c.Substring(0, $sp) }
    return $c
}

# Emits one object per service that provably references the target.
function Find-MatchingServices {
    param([string]$Target)
    $winDir = $env:SystemRoot
    $criticalNames = @('RpcSs', 'RpcEptMapper', 'DcomLaunch', 'LSM', 'SamSs', 'EventLog', 'CryptSvc', 'BFE', 'mpssvc',
                       'WinDefend', 'Winmgmt', 'TrustedInstaller', 'wuauserv', 'Dhcp', 'Dnscache', 'PlugPlay', 'Power',
                       'ProfSvc', 'Schedule', 'SENS', 'UserManager', 'gpsvc', 'LanmanServer', 'LanmanWorkstation', 'ShellHWDetection')
    $all = $null
    try { $all = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop) }
    catch {
        Write-Log 'WARN' ('Service query failed: ' + $_.Exception.Message)
        return
    }
    $targetPattern = [regex]::Escape($Target.TrimEnd('\')) + '(?=$|[\\"\s])'
    foreach ($s in $all) {
        $pathName = [string]$s.PathName
        if ([string]::IsNullOrWhiteSpace($pathName)) { continue }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($pathName)
        $exe = Get-ExecutablePath $expanded
        $reason = $null
        $shared = $false
        if ($exe -and (Test-PathUnder $exe $Target)) {
            $reason = 'The service executable is located inside the target.'
        } elseif ([regex]::IsMatch($expanded, $targetPattern, 'IgnoreCase')) {
            $reason = 'The service command line references the target path.'
        } else {
            $dll = $null
            try {
                $dll = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name + '\Parameters') -Name ServiceDll -ErrorAction Stop).ServiceDll
            } catch { $dll = $null }
            if ($dll) {
                $dll = [System.Environment]::ExpandEnvironmentVariables([string]$dll)
                if (Test-PathUnder $dll $Target) {
                    $reason = 'The service DLL (ServiceDll in its registry configuration) is located inside the target.'
                    $shared = $true
                }
            }
        }
        if (-not $reason) { continue }
        $prot = $false
        $why = ''
        if ($exe -and $winDir -and (Test-PathUnder $exe $winDir)) { $prot = $true; $why = 'its executable is inside the Windows directory' }
        if ($criticalNames -contains $s.Name) { $prot = $true; $why = 'it is a core Windows service' }
        [pscustomobject]@{
            Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; State = [string]$s.State
            StartMode = [string]$s.StartMode; PathName = $pathName; Exe = $exe; ProcessId = [int]$s.ProcessId
            Reason = $reason; Shared = $shared; Protected = $prot; ProtectedWhy = $why
        }
    }
}

function Stop-ServiceSafely {
    param([string]$Name, [int]$ProcessIdBefore)
    $r = [pscustomobject]@{ Ok = $false; Message = ''; ProcessStillRunning = $false }
    $svc = $null
    try { $svc = Get-Service -Name $Name -ErrorAction Stop }
    catch { $r.Message = 'Service not found: ' + $_.Exception.Message; return $r }

    if ($svc.Status -eq 'Stopped') { $r.Ok = $true; $r.Message = 'Service was already stopped.'; return $r }
    if (-not $svc.CanStop) {
        $r.Message = 'Windows reports that this service does not accept a Stop request while running.'
        return $r
    }
    $deps = @($svc.DependentServices | Where-Object { $_.Status -ne 'Stopped' })
    if ($deps.Count -gt 0) {
        $names = ($deps | ForEach-Object { $_.Name }) -join ', '
        $r.Message = 'Other running services depend on it (' + $names + '). Dependent services are never stopped automatically.'
        return $r
    }
    try { $svc.Stop() }
    catch {
        $ex = Get-Unwrapped $_.Exception
        $msg = $ex.Message
        if ($ex.InnerException) { $msg += ' (' + $ex.InnerException.Message + ')' }
        $r.Message = 'The Stop request failed: ' + $msg
        return $r
    }
    try { $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30)) }
    catch {
        $r.Message = 'The service did not reach the Stopped state within 30 seconds: ' + $_.Exception.Message
        return $r
    }
    # Independent verification
    $state = (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
    if ($state -ne 'Stopped') { $r.Message = 'Verification failed: current state is ' + $state + '.'; return $r }

    if ($ProcessIdBefore -gt 0) {
        for ($i = 0; $i -lt 10; $i++) {
            if (-not (Get-Process -Id $ProcessIdBefore -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }
        if (Get-Process -Id $ProcessIdBefore -ErrorAction SilentlyContinue) { $r.ProcessStillRunning = $true }
    }
    $r.Ok = $true
    $r.Message = 'Service reports Stopped (verified).'
    if ($r.ProcessStillRunning) {
        $r.Message += ' However, process ID ' + $ProcessIdBefore + ' still exists; it is NOT terminated by this tool.'
    }
    return $r
}

# Returns 'NONE' (nothing to do), 'CONTINUE' or 'CANCEL'.
function Invoke-ServiceStage {
    param([bool]$Repeat = $false)
    $script:ServiceChanged = $false
    $svcMatches = @(Find-MatchingServices -Target $script:S.Target)
    $active = @($svcMatches | Where-Object { $_.State -ne 'Stopped' })
    if ($active.Count -eq 0) {
        if (-not $Repeat) { Out-Msg INFO 'No running Windows service was found that references the target.' }
        return 'NONE'
    }
    Out-Msg STEP ''
    Out-Msg STEP '=== WINDOWS SERVICE STAGE (separate confirmation) ==='
    foreach ($svc in $active) {
        Out-Msg WARN ("A confirmed matching service is not stopped: '{0}'" -f $svc.Name)
        Out-Msg PLAIN ('Display name : ' + $svc.DisplayName)
        Out-Msg PLAIN ('State        : ' + $svc.State)
        Out-Msg PLAIN ('Startup type : ' + $svc.StartMode)
        Out-Msg PLAIN ('Executable   : ' + $svc.Exe)
        Out-Msg PLAIN ('Why matched  : ' + $svc.Reason)
        if ($svc.ProcessId -gt 0) { Out-Msg PLAIN ('Process ID    : ' + $svc.ProcessId) }
        if ($svc.Protected) {
            Out-Msg WARN ("This tool will not stop '{0}' because {1}." -f $svc.Name, $svc.ProtectedWhy)
            continue
        }
        if ($svc.Shared) {
            Out-Msg WARN 'This service loads a DLL from the target (it may share a host process). Only this service would be stopped.'
        }
        $token = 'STOP-' + $svc.Name.ToUpper()
        Write-Host ''
        Write-Host ("Type {0} to stop the identified {1} service, or press Enter to skip." -f $token, $svc.Name) -ForegroundColor White
        Write-Host '(Type C to cancel the whole operation. Typing DELETE does NOT authorise stopping a service.)' -ForegroundColor Gray
        while ($true) {
            $ans = Read-Input 'Service confirmation'
            if ($ans -eq '') { Out-Msg INFO ("Service '{0}' left running (skipped by user)." -f $svc.Name); break }
            if ($ans -match '^(c|cancel)$') { $script:S.Cancelled = $true; return 'CANCEL' }
            if ($ans -ieq $token) {
                Out-Msg INFO ("Stopping service '{0}' and waiting for it to stop..." -f $svc.Name)
                $sr = Stop-ServiceSafely -Name $svc.Name -ProcessIdBefore $svc.ProcessId
                if ($sr.Ok) {
                    Out-Msg OK ("Service '{0}': {1}" -f $svc.Name, $sr.Message)
                    $script:S.ServicesStopped += $svc.Name
                    $script:ServiceChanged = $true
                } else {
                    Out-Msg ERROR ("Could not stop service '{0}': {1}" -f $svc.Name, $sr.Message)
                    $script:S.ServiceFailures += ("{0}: {1}" -f $svc.Name, $sr.Message)
                    Out-Msg PLAIN 'The files held by this service are therefore NOT unlocked. What you can do safely:'
                    Out-Msg PLAIN '  1. Open services.msc, check the service Dependencies tab and stop dependents yourself.'
                    Out-Msg PLAIN '  2. Run  sc.exe query <name>  and  sc.exe qc <name>  to inspect state and recovery behaviour.'
                    Out-Msg PLAIN '  3. Use the vendor uninstaller for the software, if it has one.'
                    Out-Msg PLAIN '  4. Set the service startup type to Manual in services.msc, reboot, then run this tool again.'
                    Out-Msg PLAIN 'This tool never removes a service registration and never kills processes.'
                }
                break
            }
            if ($ans -ceq 'DELETE') {
                Out-Msg WARN ("'DELETE' is not accepted here. To stop the service type exactly {0}, or press Enter to skip." -f $token)
            } else {
                Out-Msg WARN ("Not recognised. Type {0}, press Enter to skip, or C to cancel." -f $token)
            }
        }
    }
    return 'CONTINUE'
}

# ---------------------------------------------------------------------------
# Diagnostics (read-only)
# ---------------------------------------------------------------------------
function Show-Diagnostics {
    param([string]$Full, [bool]$IsDir, $Inv)
    Out-Msg STEP ''
    Out-Msg STEP '=== DIAGNOSTICS (nothing has been changed yet) ==='
    $ext = ConvertTo-ExtPath $Full

    # Privileges
    if (Test-IsAdmin) { Out-Finding Confirmed 'Running with administrator privileges.' }
    else { Out-Finding Confirmed 'NOT running as administrator: ownership repair and service control will most likely fail.' }

    # Target attributes / accessibility
    try {
        $attr = [System.IO.File]::GetAttributes($ext)
        Out-Finding Confirmed ('Target is accessible. Attributes: ' + $attr)
    } catch {
        Out-Finding Confirmed ('Target attributes could not be read: ' + (Get-Unwrapped $_.Exception).Message)
    }
    if ($Inv.CntReadOnly -gt 0 -or $Inv.CntHidden -gt 0 -or $Inv.CntSystem -gt 0) {
        Out-Finding Confirmed ('Items with special attributes: {0} read-only, {1} hidden, {2} system. These attributes are cleared automatically before each deletion.' -f $Inv.CntReadOnly, $Inv.CntHidden, $Inv.CntSystem)
    }
    if ($Inv.Links.Count -gt 0) {
        Out-Finding Confirmed ('{0} link/junction/reparse item(s) inside the target. Links are removed themselves; their destinations are never touched.' -f $Inv.Links.Count)
    }
    if ($Inv.Unreadable.Count -gt 0) {
        Out-Finding Confirmed ('{0} folder(s) could not be listed (access problem). First: {1}' -f $Inv.Unreadable.Count, $Inv.Unreadable[0])
    }

    # Ownership and ACL
    $acc = Get-AccessAssessment $Full
    if ($acc.Ok) {
        Out-Finding Confirmed ('Owner: ' + $acc.Owner)
        if ($acc.Owner -match 'TrustedInstaller') { Out-Finding Possible 'Owned by TrustedInstaller: a Windows-protected resource. Deleting it may be blocked by design.' }
        if ($acc.Deny.Count -gt 0) {
            Out-Finding Confirmed ('The ACL contains an explicit DENY entry affecting delete rights for: ' + (($acc.Deny | Select-Object -Unique) -join ', ') + '. This tool never removes Deny entries.')
        }
        $parent = Get-ParentPath $Full
        $pacc = $null
        if ($parent) { $pacc = Get-AccessAssessment $parent }
        $parentOk = $false
        if ($pacc -and $pacc.Ok) {
            $parentOk = $pacc.CanDeleteChild
            Out-Finding Info ('Parent folder owner: ' + $pacc.Owner)
            if ($pacc.Deny.Count -gt 0) {
                Out-Finding Confirmed ('The PARENT folder ACL contains an explicit DENY entry for: ' + (($pacc.Deny | Select-Object -Unique) -join ', '))
            }
        } elseif ($pacc) {
            Out-Finding Possible ('Parent folder permissions could not be read: ' + $pacc.Error)
        }
        if ($acc.CanDelete -or $parentOk) {
            Out-Finding Info 'ACL analysis: your account (or one of its groups) holds Delete rights on the target or Delete-child on its parent. (Approximation of Windows access checks.)'
        } else {
            Out-Finding Possible 'ACL analysis: no entry grants your account Delete on the target or Delete-child on its parent. Permission repair may be needed. (Approximation: privileges are not evaluated.)'
        }
    } else {
        Out-Finding Possible ('Ownership/permissions could not be read: ' + $acc.Error + ' (this itself suggests an access-rights problem).')
    }

    # Volume
    try {
        $root = [System.IO.Path]::GetPathRoot($Full)
        if ($root.StartsWith('\\')) {
            Out-Finding Info 'Target is on a network share: deletion rights are decided by the server and share permissions.'
        } else {
            $di = New-Object System.IO.DriveInfo($root.Substring(0, 1))
            if (-not $di.IsReady) {
                Out-Finding Possible 'The volume reports it is not ready.'
            } else {
                Out-Finding Info ('Volume {0} is {1}, file system {2}.' -f $root, $di.DriveType, $di.DriveFormat)
                if ($di.DriveType -eq 'CDRom' -or $di.DriveFormat -in @('CDFS', 'UDF')) { Out-Finding Confirmed 'The volume is optical/read-only media. Files cannot be deleted from it.' }
                elseif ($di.DriveType -eq 'Removable') { Out-Finding Possible 'Removable media: a hardware write-protect switch cannot be detected without writing.' }
                else { Out-Finding Info 'No read-only volume was detected. (A write-protected volume is only confirmed if Windows returns error 19.)' }
            }
        }
    } catch {
        Out-Finding Possible ('Volume information unavailable: ' + $_.Exception.Message)
    }

    # Security software
    $sec = Get-SecurityInfo
    if ($sec.DefenderAvailable) {
        Out-Finding Info ('Microsoft Defender real-time protection: ' + $sec.RealTime)
    }
    if ($null -ne $sec.Cfa) {
        if ($sec.Cfa -eq 1 -or $sec.Cfa -eq 3) { Out-Finding Possible 'Defender Controlled Folder Access is ON; it can block changes to protected folders. Check Windows Security > Protection history.' }
        else { Out-Finding Info ('Defender Controlled Folder Access setting: ' + $sec.Cfa + ' (not blocking).') }
    }
    if ($sec.ThirdParty.Count -gt 0) {
        Out-Finding Possible ('Registered security product(s): ' + (($sec.ThirdParty | Select-Object -Unique) -join ', ') + '. Whether one blocks this deletion cannot be determined here.')
    }
    if (-not $sec.DefenderAvailable -and $null -eq $sec.Cfa -and $sec.ThirdParty.Count -eq 0) {
        Out-Finding Info 'Security-software state could not be determined through supported interfaces.'
    }

    # Locks (Restart Manager)
    $checkFiles = New-Object 'System.Collections.Generic.List[string]'
    $execFiles = @($Inv.Files | Where-Object { $_ -match '\.(exe|dll|sys|ocx|drv|node)$' } | Select-Object -First 3000)
    foreach ($f in $execFiles) { $checkFiles.Add($f) }
    foreach ($f in $Inv.Files) {
        if ($checkFiles.Count -ge 5000) { break }
        if ($f -notmatch '\.(exe|dll|sys|ocx|drv|node)$') { $checkFiles.Add($f) }
    }
    $lock = Get-FileLockers -Files $checkFiles.ToArray()
    if (-not $lock.Known) {
        Out-Finding Possible 'Process/file-lock identification was not available (Restart Manager could not be used). Lock status is UNKNOWN.'
    } elseif ($lock.Items.Count -gt 0) {
        foreach ($li in $lock.Items) {
            $svcTxt = ''
            if ($li.Service) { $svcTxt = ', service: ' + $li.Service }
            Out-Finding Confirmed ('Windows Restart Manager reports PID {0} ({1}{2}) is using {3} file(s) in the target.' -f $li.ProcessId, $li.Name, $svcTxt, $li.Count)
        }
    } else {
        Out-Finding Info ('Restart Manager reported no process using the {0} file(s) checked. This does not prove that no lock exists.' -f $checkFiles.Count)
    }
    if ($Inv.Files.Count -gt $checkFiles.Count) { Out-Finding Info ('Only {0} of {1} files were checked for locks.' -f $checkFiles.Count, $Inv.Files.Count) }

    # Services
    $svcMatches = @(Find-MatchingServices -Target $Full)
    if ($svcMatches.Count -eq 0) {
        Out-Finding Info 'No Windows service executable, command line or ServiceDll references the target. (Kernel drivers and scheduled tasks are not checked.)'
    } else {
        foreach ($s in $svcMatches) {
            Out-Finding Confirmed ("Service '{0}' ({1}), startup {2}, runs {3}. {4}" -f $s.Name, $s.State, $s.StartMode, $s.Exe, $s.Reason)
        }
    }
    $script:S.ServiceMatches = $svcMatches
}

# ---------------------------------------------------------------------------
# Deletion engine
# ---------------------------------------------------------------------------
function Invoke-SingleDelete {
    param([string]$Ext, [bool]$IsDir)
    $r = [pscustomobject]@{ Ok = $false; Gone = $false; Category = ''; Code = 0; Message = ''; Attempts = 1 }
    try {
        try { [System.IO.File]::SetAttributes($Ext, [System.IO.FileAttributes]::Normal) } catch { }
        if ($IsDir) { [System.IO.Directory]::Delete($Ext, $false) } else { [System.IO.File]::Delete($Ext) }
        $r.Ok = $true
        return $r
    } catch {
        $ex = Get-Unwrapped $_.Exception
        $code = 0
        try { $code = [int]($ex.HResult -band 0xFFFF) } catch { }
        $r.Code = $code
        $r.Message = $ex.Message
        $cat = 'Unknown'
        if ($ex -is [System.IO.PathTooLongException]) { $cat = 'PathTooLong' }
        elseif ($ex -is [System.UnauthorizedAccessException]) { $cat = 'AccessDenied'; if ($code -eq 0) { $r.Code = 5 } }
        elseif ($ex -is [System.IO.DirectoryNotFoundException] -or $ex -is [System.IO.FileNotFoundException]) { $cat = 'NotFound' }
        elseif ($ex -is [System.IO.IOException]) {
            switch ($code) {
                { $_ -in @(32, 33) }   { $cat = 'InUse' }
                145                    { $cat = 'DirectoryNotEmpty' }
                19                     { $cat = 'ReadOnlyVolume' }
                5                      { $cat = 'AccessDenied' }
                { $_ -in @(2, 3) }     { $cat = 'NotFound' }
                { $_ -in @(123, 161, 206) } { $cat = 'InvalidPath' }
                { $_ -in @(1, 50, 120, 1920) } { $cat = 'Unsupported' }
                default                { $cat = 'Unknown' }
            }
        }
        $r.Category = $cat
        if ($cat -eq 'NotFound') { $r.Ok = $true; $r.Gone = $true }
        return $r
    }
}

# Bounded retry: only InUse / DirectoryNotEmpty are treated as transient (3 attempts, 750 ms apart).
function Remove-OneItem {
    param([string]$P, [bool]$IsDir)
    $ext = ConvertTo-ExtPath $P
    $last = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $last = Invoke-SingleDelete -Ext $ext -IsDir $IsDir
        $last.Attempts = $attempt
        if ($last.Ok) { return $last }
        if (($last.Category -eq 'InUse' -or $last.Category -eq 'DirectoryNotEmpty') -and $attempt -lt 3) {
            Start-Sleep -Milliseconds 750
            continue
        }
        break
    }
    return $last
}

function Update-DeleteProgress {
    param([int]$Done, [int]$Total)
    if ($Done -eq $Total -or ($Done % 20) -eq 0 -or $Total -le 50) {
        $pct = [int](100 * $Done / [Math]::Max(1, $Total))
        Write-Progress -Activity 'Deleting' -Status ('{0} of {1} items processed' -f $Done, $Total) -PercentComplete $pct
    }
}

function New-FailureRecord {
    param([string]$P, [bool]$IsDir, $Res)
    return [pscustomobject]@{
        Path = $P; IsDir = $IsDir; Category = $Res.Category; Code = $Res.Code
        Message = $Res.Message; Attempts = $Res.Attempts
    }
}

function Invoke-DeletionPass {
    param($Inv)
    $failures = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[string]'
    $blocked = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $total = $Inv.Files.Count + $Inv.Dirs.Count
    $done = 0
    $fd = 0
    $dd = 0

    foreach ($f in $Inv.Files) {
        $done++
        Update-DeleteProgress $done $total
        $res = Remove-OneItem -P $f -IsDir $false
        if ($res.Ok) {
            $fd++
            if ($res.Gone) { Write-Log 'GONE' ('file already absent: ' + $f) } else { Write-Log 'DELETED' ('file: ' + $f) }
        } else {
            $failures.Add((New-FailureRecord $f $false $res))
            Write-Log 'FAILED' ('file: {0} | {1} | Win32 {2} | {3}' -f $f, $res.Category, $res.Code, $res.Message)
            $pp = Get-ParentPath $f
            if ($pp) { [void]$blocked.Add($pp) }
        }
    }
    for ($i = $Inv.Dirs.Count - 1; $i -ge 0; $i--) {
        $d = $Inv.Dirs[$i]
        $done++
        Update-DeleteProgress $done $total
        if ($blocked.Contains($d)) {
            $skipped.Add($d)
            Write-Log 'SKIPPED' ('folder not attempted because it still contains undeleted items: ' + $d)
            $pp = Get-ParentPath $d
            if ($pp) { [void]$blocked.Add($pp) }
            continue
        }
        $res = Remove-OneItem -P $d -IsDir $true
        if ($res.Ok) {
            $dd++
            Write-Log 'DELETED' ('folder: ' + $d)
        } else {
            if ($Inv.Unreadable.Contains($d)) {
                $res.Category = 'AccessDenied'
                $res.Message = 'Folder contents could not be listed (access denied while enumerating). ' + $res.Message
            }
            $failures.Add((New-FailureRecord $d $true $res))
            Write-Log 'FAILED' ('folder: {0} | {1} | Win32 {2} | {3}' -f $d, $res.Category, $res.Code, $res.Message)
            $pp = Get-ParentPath $d
            if ($pp) { [void]$blocked.Add($pp) }
        }
    }
    Write-Progress -Activity 'Deleting' -Completed
    $script:S.FilesDeleted += $fd
    $script:S.DirsDeleted += $dd
    $script:S.FailureMap = @{}
    foreach ($f in $failures) { $script:S.FailureMap[$f.Path] = $f }
    Out-Msg INFO ('This pass: {0} file(s) and {1} folder(s) deleted, {2} failure(s), {3} folder(s) skipped.' -f $fd, $dd, $failures.Count, $skipped.Count)
    return [pscustomobject]@{ Failures = $failures; Skipped = $skipped; FilesDeleted = $fd; DirsDeleted = $dd }
}

function Get-CategoryAdvice {
    param([string]$Category)
    switch ($Category) {
        'AccessDenied'      { return 'Windows denied access. Possible causes (not all confirmed): restrictive ACL or ownership, Controlled Folder Access/security software, or a lock that Windows reports as access denied. Next: lock analysis below, then the permission-repair stage.' }
        'InUse'             { return 'The file is open in another process (sharing/lock violation, Win32 32/33). Next: identify the process below, close that program or stop the matching service, then retry.' }
        'DirectoryNotEmpty' { return 'The folder is not empty (Win32 145). Usually a child item failed, or a running program created files while deleting.' }
        'ReadOnlyVolume'    { return 'The volume or media is write-protected/read-only (Win32 19). This tool cannot change that.' }
        'PathTooLong'       { return 'The path is too long for this operation. Try moving/renaming a parent folder closer to the drive root.' }
        'InvalidPath'       { return 'Windows rejected the path as invalid (Win32 123/161/206). Check for unusual names or a broken link.' }
        'Unsupported'       { return 'The file system does not support this operation on this item (for example a special reparse point).' }
        default             { return 'Unclassified error. See the exact message and Win32 code below and in the log.' }
    }
}

function Show-FailureReport {
    param($Failures, $Skipped)
    if ($Failures.Count -eq 0) { return }
    Out-Msg STEP ''
    Out-Msg STEP '=== WHAT COULD NOT BE DELETED ==='
    $groups = $Failures | Group-Object Category
    foreach ($g in $groups) {
        Out-Msg ERROR ('{0}: {1} item(s)' -f $g.Name, $g.Count)
        Out-Msg PLAIN (Get-CategoryAdvice $g.Name)
        $shown = 0
        foreach ($f in $g.Group) {
            if ($shown -lt 10) {
                Write-Host ('         {0}  [Win32 {1}] {2}' -f $f.Path, $f.Code, $f.Message) -ForegroundColor DarkYellow
            }
            $shown++
        }
        if ($g.Count -gt 10) { Write-Host ('         ... and {0} more (all are listed in the log)' -f ($g.Count - 10)) -ForegroundColor DarkYellow }
    }
    if ($Skipped.Count -gt 0) {
        Out-Msg INFO ('{0} parent folder(s) were not attempted because they still contain the items above.' -f $Skipped.Count)
    }
}

function Show-LockAnalysis {
    param($Failures)
    $cand = @($Failures | Where-Object { -not $_.IsDir -and ($_.Category -eq 'InUse' -or $_.Category -eq 'AccessDenied') } | Select-Object -First 25)
    if ($cand.Count -eq 0) { return }
    Out-Msg STEP ''
    Out-Msg STEP '=== LOCK ANALYSIS OF FAILED FILES ==='
    $agg = @{}
    $known = $false
    foreach ($f in $cand) {
        $lock = Get-FileLockers -Files @($f.Path)
        if ($lock.Known) { $known = $true }
        foreach ($li in $lock.Items) {
            $k = [string]$li.ProcessId
            if ($agg.ContainsKey($k)) { $agg[$k].Count++ }
            else { $agg[$k] = [pscustomobject]@{ ProcessId = $li.ProcessId; Name = $li.Name; Service = $li.Service; Count = 1 } }
        }
    }
    if ($agg.Count -gt 0) {
        foreach ($li in $agg.Values) {
            $svcTxt = ''
            if ($li.Service) { $svcTxt = ', service: ' + $li.Service }
            Out-Finding Confirmed ('Windows Restart Manager: PID {0} ({1}{2}) holds {3} of the {4} failed file(s) checked.' -f $li.ProcessId, $li.Name, $svcTxt, $li.Count, $cand.Count)
        }
        Out-Msg PLAIN 'Close that application normally (or stop its service, if offered). This tool will not terminate processes or close handles.'
    } else {
        if ($known) { Out-Msg WARN 'The lock was NOT identified: Restart Manager found no process for the failed files.' }
        else { Out-Msg WARN 'The lock was NOT identified: Restart Manager is unavailable.' }
        Out-Msg PLAIN 'No process is blamed without evidence. To investigate further use official Microsoft Sysinternals tools:'
        Out-Msg PLAIN '  - Process Explorer: Find > Find Handle or DLL (Ctrl+F), enter the file name.'
        Out-Msg PLAIN '  - Handle:  handle.exe -accepteula "<full path of the file>"  (run as administrator)'
        Out-Msg PLAIN '  Download: https://learn.microsoft.com/sysinternals/'
        Out-Msg PLAIN 'Close the program normally; do not force-close handles of unknown processes.'
    }
}

# ---------------------------------------------------------------------------
# Permission repair (separate stage)
# ---------------------------------------------------------------------------
function Invoke-External {
    param([string]$Exe, [string]$Arguments)
    $r = [pscustomobject]@{ ExitCode = -1; Output = '' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(180000)) {
            try { $p.Kill() } catch { }
            $r.Output = 'Timed out after 180 seconds.'
            return $r
        }
        $p.WaitForExit()
        $r.ExitCode = $p.ExitCode
        $r.Output = (($so.Result + ' ' + $se.Result) -replace '\s+', ' ').Trim()
    } catch {
        $r.Output = 'Could not start ' + $Exe + ': ' + $_.Exception.Message
    }
    Write-Log 'EXEC' ('{0} {1} -> exit {2}: {3}' -f $Exe, $Arguments, $r.ExitCode, $r.Output)
    return $r
}

function Test-RepairVerified {
    param([string]$P, [bool]$ExpectOwner)
    $a = Get-AccessAssessment $P
    if (-not $a.Ok) { return $false }
    if (-not $a.AdminFull) { return $false }
    if ($ExpectOwner -and $a.OwnerSid -ne $script:AdminSid) { return $false }
    return $true
}

# Returns $true if at least one item was repaired and verified.
function Invoke-PermissionRepair {
    param($Failures)
    $S = $script:S
    $sys32 = Join-Path $env:SystemRoot 'System32'
    $takeown = Join-Path $sys32 'takeown.exe'
    $icacls = Join-Path $sys32 'icacls.exe'
    $attrib = Join-Path $sys32 'attrib.exe'

    $targets = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Failures) {
        if ($seen.Add($f.Path)) { $targets.Add($f.Path) }
        $pp = Get-ParentPath $f.Path
        if ($pp -and (Test-PathUnder $pp $S.Target) -and $seen.Add($pp)) { $targets.Add($pp) }
    }

    Out-Msg STEP ''
    Out-Msg STEP '=== PERMISSION REPAIR ==='
    $okCount = 0
    $failCount = 0

    if ($targets.Count -gt 300 -and $S.IsDir) {
        Out-Msg INFO ('{0} items need repair; using one recursive pass limited to the selected target.' -f $targets.Count)
        $t = $S.Target
        $r1 = Invoke-External $takeown ('/F "{0}" /R /A /D Y' -f $t)
        Out-Msg PLAIN ('takeown exit code {0}' -f $r1.ExitCode)
        $r2 = Invoke-External $icacls ('"{0}" /grant *{1}:(OI)(CI)(F) /T /C /L' -f $t, $script:AdminSid)
        Out-Msg PLAIN ('icacls exit code {0}' -f $r2.ExitCode)
        $r3 = Invoke-External $attrib ('-R -S -H "{0}\*" /S /D /L' -f $t)
        Out-Msg PLAIN ('attrib exit code {0}' -f $r3.ExitCode)
        $sample = @($targets | Select-Object -First 20)
        $verified = 0
        foreach ($sp in $sample) {
            if (Test-RepairVerified -P $sp -ExpectOwner (-not (Test-ReparseFlag $sp))) { $verified++ }
        }
        if ($verified -eq $sample.Count -and $r2.ExitCode -eq 0) {
            Out-Msg OK ('Repair verified on a sample of {0} item(s).' -f $sample.Count)
            $okCount = $targets.Count
        } else {
            Out-Msg ERROR ('Verification: {0} of {1} sampled items confirmed repaired. icacls said: {2}' -f $verified, $sample.Count, $r2.Output)
            if ($verified -gt 0) { $okCount = 1 }
            $failCount = $targets.Count
        }
    } else {
        Out-Msg INFO ('Repairing {0} item(s): failed items and their parent folders inside the target only.' -f $targets.Count)
        foreach ($t in $targets) {
            $isLink = Test-ReparseFlag $t
            $notes = New-Object 'System.Collections.Generic.List[string]'
            $good = $true
            if (-not $isLink) {
                $r1 = Invoke-External $takeown ('/F "{0}" /A' -f $t)
                if ($r1.ExitCode -ne 0) { $good = $false; $notes.Add(('takeown exit {0}: {1}' -f $r1.ExitCode, $r1.Output)) }
            }
            $r2 = Invoke-External $icacls ('"{0}" /grant *{1}:(F) /C /L' -f $t, $script:AdminSid)
            if ($r2.ExitCode -ne 0) { $good = $false; $notes.Add(('icacls exit {0}: {1}' -f $r2.ExitCode, $r2.Output)) }
            $isDirItem = $false
            try { $isDirItem = [System.IO.Directory]::Exists((ConvertTo-ExtPath $t)) } catch { }
            if ($isDirItem) { [void](Invoke-External $attrib ('-R -S -H "{0}" /D /L' -f $t)) }
            else { [void](Invoke-External $attrib ('-R -S -H "{0}" /L' -f $t)) }
            if ($good -and -not (Test-RepairVerified -P $t -ExpectOwner (-not $isLink))) {
                $good = $false
                $notes.Add('command succeeded but the new owner/ACL entry could not be verified')
            }
            if ($good) { $okCount++ }
            else {
                $failCount++
                Out-Msg ERROR ('Repair failed for {0}: {1}' -f $t, ($notes -join '; '))
            }
            $after = Get-AccessAssessment $t
            if ($after.Ok -and $after.Deny.Count -gt 0) {
                Out-Msg WARN ('An explicit DENY entry for {0} remains on {1}. This tool does not remove Deny entries; remove it yourself with icacls /remove:d if you are authorised.' -f (($after.Deny | Select-Object -Unique) -join ', '), $t)
            }
        }
    }
    if ($okCount -gt 0) {
        Out-Msg OK ('Permission repair: {0} item(s) repaired and verified, {1} failed.' -f $okCount, $failCount)
        $S.Repaired = $true
    } else {
        Out-Msg ERROR ('Permission repair did not succeed ({0} failed). Deletion will probably fail again.' -f $failCount)
    }
    return ($okCount -gt 0)
}

# ---------------------------------------------------------------------------
# Operation
# ---------------------------------------------------------------------------
function New-OpState {
    $script:S = [pscustomobject]@{
        Target = ''; IsDir = $false; Start = (Get-Date)
        FilesDeleted = 0; DirsDeleted = 0
        FailureMap = @{}
        ServiceMatches = @(); ServicesStopped = @(); ServiceFailures = @()
        Repaired = $false; Rounds = 0; Cancelled = $false
    }
    $script:ServiceChanged = $false
}

function Get-FinalStatus {
    $S = $script:S
    $exists = Test-TargetExists
    if (-not $exists) { return 'SUCCESS' }
    $deleted = $S.FilesDeleted + $S.DirsDeleted
    if ($S.Cancelled -and $deleted -eq 0) { return 'CANCELLED' }
    if ($deleted -gt 0) { return 'PARTIAL' }
    return 'FAILED'
}

function Invoke-OperationCore {
    param([string]$InputPath)
    $S = $script:S

    $raw = $InputPath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host ''
        Write-Host 'Enter the FULL path of the file or folder to delete.' -ForegroundColor White
        Write-Host 'Spaces are fine; surrounding quotes are optional. Type C (or press Enter) to cancel.' -ForegroundColor Gray
        $raw = Read-Input 'Path'
    }
    if ($raw -eq '' -or $raw -match '^(c|cancel)$') {
        Out-Msg INFO 'Cancelled: no path entered.'
        $S.Cancelled = $true
        return 'CANCELLED'
    }
    $rp = Resolve-TargetPath $raw
    if (-not $rp.Ok) {
        Out-Msg ERROR ('Invalid path: ' + $rp.Error)
        return 'FAILED'
    }
    $full = $rp.Full
    $S.Target = $full
    Write-Log 'INFO' ('Target path: ' + $full)

    $ext = ConvertTo-ExtPath $full
    $isFile = [System.IO.File]::Exists($ext)
    $isDir = [System.IO.Directory]::Exists($ext)
    if (-not ($isFile -or $isDir)) {
        Out-Msg ERROR ('The target does not exist or is not accessible: ' + $full)
        Out-Msg PLAIN 'Check the spelling and that the drive is connected. Nothing was changed.'
        return 'FAILED'
    }
    $S.IsDir = $isDir

    $reason = Get-ProtectedReason $full
    if ($reason) {
        Out-Msg ERROR ('REFUSED: ' + $reason)
        Out-Msg PLAIN 'This tool will never delete drive roots, Windows directories or other protected locations. Nothing was changed.'
        return 'FAILED'
    }

    Out-Msg STEP ''
    Out-Msg STEP '=== TARGET ==='
    Out-Msg INFO ('Resolved path: ' + $full)
    Out-Msg INFO 'Scanning (links are not followed)...'
    $inv = Get-TargetInventory $full
    $kind = 'File'
    if ($isDir) { $kind = 'Folder' }
    if ($isDir -and $inv.Links.Count -gt 0 -and $inv.Dirs.Count -eq 1 -and $inv.Dirs[0] -eq $full) { $kind = 'Link/junction (only the link itself will be removed)' }
    Out-Msg INFO ('Type: {0}' -f $kind)
    $folderCount = $inv.Dirs.Count
    if ($isDir) { Out-Msg INFO ('Contains: {0} file(s), {1} folder(s) including the target, {2} link(s), {3}' -f $inv.Files.Count, $folderCount, $inv.Links.Count, (Format-Size $inv.Bytes)) }
    else { Out-Msg INFO ('Size: ' + (Format-Size $inv.Bytes)) }
    foreach ($e in $inv.Errors) { Out-Msg WARN ('Could not read folder: ' + $e) }
    $caution = Get-CautionNote $full
    if ($caution) { Out-Msg WARN $caution }

    Show-Diagnostics -Full $full -IsDir $isDir -Inv $inv

    # Permanent deletion confirmation
    Write-Host ''
    Write-Host ('!' * 72) -ForegroundColor Red
    Write-Host '  PERMANENT DELETION WARNING' -ForegroundColor Red
    Write-Host '  Items are deleted immediately. They do NOT go to the Recycle Bin.' -ForegroundColor Red
    Write-Host '  This cannot be undone.' -ForegroundColor Red
    Write-Host ('  Target: ' + $full) -ForegroundColor White
    Write-Host ('!' * 72) -ForegroundColor Red
    Write-Host 'Type DELETE (exact, upper-case) to proceed, or press Enter / C to cancel.' -ForegroundColor White
    $c = Read-Input 'Confirmation'
    if ($c -cne 'DELETE') {
        Out-Msg INFO 'Cancelled by user. Nothing was deleted.'
        $S.Cancelled = $true
        return 'CANCELLED'
    }
    Write-Log 'INFO' 'User confirmed permanent deletion.'

    # Service stage (separate confirmation)
    $sr = Invoke-ServiceStage -Repeat $false
    if ($sr -eq 'CANCEL') {
        Out-Msg INFO 'Cancelled by user at the service stage. Nothing was deleted.'
        return (Get-FinalStatus)
    }
    if ($script:ServiceChanged) { $inv = Get-TargetInventory $full }

    # Deletion rounds (bounded)
    $maxRounds = 5
    $round = 0
    while ($true) {
        $round++
        $S.Rounds = $round
        Out-Msg STEP ''
        Out-Msg STEP ('=== DELETION ATTEMPT {0} (maximum {1}) ===' -f $round, $maxRounds)
        $pass = Invoke-DeletionPass -Inv $inv
        if (-not (Test-TargetExists)) { break }
        if ($pass.Failures.Count -eq 0 -and $pass.Skipped.Count -eq 0) { break }

        Show-FailureReport -Failures $pass.Failures -Skipped $pass.Skipped
        Show-LockAnalysis -Failures $pass.Failures
        if ($round -ge $maxRounds) {
            Out-Msg WARN 'The maximum number of attempts was reached. Stopping to avoid pointless repetition.'
            break
        }

        $changed = $false
        $denied = @($pass.Failures | Where-Object { $_.Category -eq 'AccessDenied' })
        $hasInUse = (@($pass.Failures | Where-Object { $_.Category -eq 'InUse' }).Count -gt 0)
        $hasOther = (@($pass.Failures | Where-Object { $_.Category -eq 'DirectoryNotEmpty' -or $_.Category -eq 'Unknown' }).Count -gt 0)

        if ($denied.Count -gt 0) {
            Write-Host ''
            Write-Host ('{0} item(s) failed with access denied. Permission repair takes ownership and grants Administrators full control' -f $denied.Count) -ForegroundColor White
            Write-Host 'on those items and their parent folders INSIDE the target only. It does not touch security software or UAC.' -ForegroundColor White
            Write-Host 'Type REPAIR to run it, press Enter to skip, or C to cancel.' -ForegroundColor White
            while ($true) {
                $a = Read-Input 'Repair confirmation'
                if ($a -eq '') { Out-Msg INFO 'Permission repair skipped.'; break }
                if ($a -match '^(c|cancel)$') { $S.Cancelled = $true; break }
                if ($a -ieq 'REPAIR') {
                    if (Invoke-PermissionRepair -Failures $denied) { $changed = $true }
                    break
                }
                Out-Msg WARN 'Not recognised. Type REPAIR, press Enter to skip, or C to cancel.'
            }
            if ($S.Cancelled) { Out-Msg INFO 'Cancelled by user.'; break }
        }

        if ($hasInUse -or $denied.Count -gt 0) {
            $sr2 = Invoke-ServiceStage -Repeat $true
            if ($sr2 -eq 'CANCEL') { Out-Msg INFO 'Cancelled by user.'; break }
            if ($script:ServiceChanged) { $changed = $true }
        }

        if (-not ($changed -or $hasInUse -or $hasOther)) {
            Out-Msg WARN 'Nothing has changed since the last attempt, so retrying would only repeat the same failure. Not retrying.'
            break
        }
        Write-Host ''
        Write-Host 'If you closed a program or changed something, press Enter to retry the remaining items, or type Q to finish.' -ForegroundColor White
        $ans = Read-Input 'Retry'
        if ($ans -match '^(q|quit|c|cancel)$') { break }
        $inv = Get-TargetInventory $full
    }
    return (Get-FinalStatus)
}

function Show-FinalSummary {
    param([string]$Status)
    $S = $script:S
    $dur = (Get-Date) - $S.Start
    $color = 'Red'
    switch ($Status) {
        'SUCCESS'   { $color = 'Green' }
        'PARTIAL'   { $color = 'Yellow' }
        'CANCELLED' { $color = 'Gray' }
        default     { $color = 'Red' }
    }
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ('  FINAL STATUS: ' + $Status) -ForegroundColor $color
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Log 'SUMMARY' ('Status={0} Target={1}' -f $Status, $S.Target)
    if ($S.Target) { Out-Msg INFO ('Target: ' + $S.Target) }
    Out-Msg INFO ('Deleted: {0} file(s), {1} folder(s). Duration: {2:N1} s. Attempts: {3}.' -f $S.FilesDeleted, $S.DirsDeleted, $dur.TotalSeconds, $S.Rounds)
    if ($S.ServicesStopped.Count -gt 0) { Out-Msg INFO ('Services stopped on your confirmation: ' + ($S.ServicesStopped -join ', ')) }
    foreach ($f in $S.ServiceFailures) { Out-Msg WARN ('Service stop failed - ' + $f) }
    if ($S.Repaired) { Out-Msg INFO 'Permission repair was performed on failed items.' }

    if ($Status -eq 'SUCCESS') {
        Out-Msg OK 'The target no longer exists. Deletion verified.'
    } elseif ($S.Target -and (Test-TargetExists)) {
        $rem = Get-TargetInventory $S.Target
        $items = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $rem.Files) { $items.Add($f) }
        for ($i = $rem.Dirs.Count - 1; $i -ge 0; $i--) { $items.Add($rem.Dirs[$i]) }
        if ($Status -eq 'PARTIAL') { Out-Msg WARN ('PARTIAL: {0} item(s) still remain. The target was NOT completely deleted.' -f $items.Count) }
        elseif ($Status -eq 'FAILED') { Out-Msg ERROR ('FAILED: nothing was deleted; {0} item(s) remain.' -f $items.Count) }
        else { Out-Msg INFO ('{0} item(s) remain (nothing was deleted).' -f $items.Count) }
        $shown = 0
        foreach ($p in $items) {
            $why = 'not deleted (parent of an undeleted item, or not attempted)'
            if ($S.FailureMap.ContainsKey($p)) {
                $fr = $S.FailureMap[$p]
                $why = '{0}, Win32 {1}: {2}' -f $fr.Category, $fr.Code, $fr.Message
            }
            Write-Log 'REMAINING' ('{0} | {1}' -f $p, $why)
            if ($shown -lt 50) { Write-Host ('   remains: {0}  ->  {1}' -f $p, $why) -ForegroundColor DarkYellow }
            $shown++
        }
        if ($items.Count -gt 50) { Write-Host ('   ... and {0} more (all listed in the log)' -f ($items.Count - 50)) -ForegroundColor DarkYellow }
        Out-Msg PLAIN 'Next steps: close the programs identified above, stop the matching service if appropriate, or use Sysinternals Process Explorer/Handle, then run this tool again.'
    }
    if ($script:LogPath) { Write-Host ('  Log file: ' + $script:LogPath) -ForegroundColor White }
}

function Invoke-Operation {
    param([string]$InputPath = '')
    New-OpState
    Open-Log
    Write-Log 'INFO' ('{0} v{1}' -f $script:AppName, $script:AppVersion)
    Write-Log 'INFO' ('Started at: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Log 'INFO' ('Administrator: ' + (Test-IsAdmin))
    Write-Log 'INFO' ('User: ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    Write-Log 'INFO' ('PowerShell: ' + $PSVersionTable.PSVersion + ' | OS: ' + [System.Environment]::OSVersion.VersionString)
    $status = 'FAILED'
    try {
        $result = Invoke-OperationCore -InputPath $InputPath
        $status = [string](@($result)[-1])
    } catch {
        Out-Msg ERROR ('Unexpected internal error: ' + $_.Exception.Message)
        Write-Log 'ERROR' ($_ | Out-String)
        $status = 'FAILED'
    }
    if ($status -notin @('SUCCESS', 'PARTIAL', 'CANCELLED', 'FAILED')) { $status = 'FAILED' }
    Show-FinalSummary -Status $status
    Close-Log -Status $status
}

# ---------------------------------------------------------------------------
# Test fixtures (disposable data only)
# ---------------------------------------------------------------------------
function New-TestFixtures {
    $root = Join-Path $env:TEMP 'ForceDelete Pro Test'
    [void][System.IO.Directory]::CreateDirectory($root)

    $d1 = Join-Path $root '01 normal'
    [void][System.IO.Directory]::CreateDirectory($d1)
    Set-Content -LiteralPath (Join-Path $d1 'file.txt') -Value 'test'

    $d2 = Join-Path $root '02 nested\level1\level2\level3'
    [void][System.IO.Directory]::CreateDirectory($d2)
    Set-Content -LiteralPath (Join-Path $d2 'deep.txt') -Value 'deep'
    Set-Content -LiteralPath (Join-Path $root '02 nested\level1\mid.txt') -Value 'mid'

    $d3 = Join-Path $root '03 hidden and readonly'
    [void][System.IO.Directory]::CreateDirectory($d3)
    $f = Join-Path $d3 'readonly.txt'; Set-Content -LiteralPath $f -Value 'ro'
    [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::ReadOnly)
    $f = Join-Path $d3 'hidden.txt'; Set-Content -LiteralPath $f -Value 'hid'
    [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Hidden)
    $f = Join-Path $d3 'system.txt'; Set-Content -LiteralPath $f -Value 'sys'
    [System.IO.File]::SetAttributes($f, ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System))

    $d4 = Join-Path $root '04 locked'
    [void][System.IO.Directory]::CreateDirectory($d4)
    Set-Content -LiteralPath (Join-Path $d4 'held.txt') -Value 'lock me'

    $d5 = Join-Path $root '05 service'
    [void][System.IO.Directory]::CreateDirectory($d5)

    $d7 = Join-Path $root '07 denied'
    [void][System.IO.Directory]::CreateDirectory($d7)
    Set-Content -LiteralPath (Join-Path $d7 'secret.txt') -Value 'denied'

    Set-Content -LiteralPath (Join-Path $root 'single file.txt') -Value 'single'

    Write-Host ''
    Write-Host 'Disposable test data created under:' -ForegroundColor Green
    Write-Host ('  ' + $root) -ForegroundColor White
    Get-ChildItem -LiteralPath $root -Force | ForEach-Object { Write-Host ('  - ' + $_.Name) }
    Write-Host ''
    Write-Host 'See README.md (Testing) for how to use each folder.' -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Menu / entry point
# ---------------------------------------------------------------------------
function Start-MainMenu {
    while ($true) {
        Show-Banner
        Write-Host ''
        Write-Host '  [1] Delete a file or folder'
        Write-Host '  [2] Show log folder'
        Write-Host '  [Q] Quit'
        $c = Read-Host 'Select an option'
        if ($null -eq $c) { return }
        switch -regex ($c.Trim()) {
            '^1$' {
                Invoke-Operation -InputPath ''
                [void](Read-Host 'Press Enter to return to the main menu')
            }
            '^2$' {
                $dir = Get-LogDirectory
                if ($dir) {
                    Write-Host ('Logs are written to: ' + $dir) -ForegroundColor White
                    $o = Read-Host 'Open this folder in Explorer? (Y/N)'
                    if ($o -and $o.Trim() -match '^(y|yes)$') {
                        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) } catch { }
                    }
                } else {
                    Write-Host 'No writable log directory is available.' -ForegroundColor Yellow
                }
                [void](Read-Host 'Press Enter to return to the main menu')
            }
            '^(q|quit|exit)$' { return }
            default { }
        }
    }
}

function Start-Program {
    if ($CreateFixtures) { New-TestFixtures; return }
    if (Request-Elevation) { return }
    if ($Path) {
        Show-Banner
        Invoke-Operation -InputPath $Path
        [void](Read-Host 'Press Enter to continue to the main menu')
    }
    Start-MainMenu
    Write-Host 'Goodbye.'
}

try {
    Start-Program
} finally {
    if ($Elevated) { [void](Read-Host 'Press Enter to close this window') }
}
exit 0
