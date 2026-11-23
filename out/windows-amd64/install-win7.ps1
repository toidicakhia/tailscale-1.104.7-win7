#requires -Version 2.0
<#
.SYNOPSIS
    Installs the Tailscale 1.104.7 Windows 7/8 compatibility build.

.DESCRIPTION
    Replicates the official Tailscale MSI (service, ACLs, registry, shortcuts,
    system PATH) using the patched 1.104.7 binaries in this package.

    Run from an elevated PowerShell prompt, or right-click install-win7.cmd
    and choose "Run as administrator".

.PARAMETER InstallDir
    Installation directory. Default: %ProgramW6432%\Tailscale

.PARAMETER NoGui
    Install the service and CLI only. The GUI, URL handler, and GUI shortcuts
    are skipped.

.PARAMETER NoStart
    Do not start the service after installation.

.PARAMETER PreInstallWintun
    Stage the Wintun driver package with pnputil before first use. Wintun can
    also install its driver on demand, so this is optional.

.PARAMETER KeepAutoUpdate
    Do not write the machine policy that disables Tailscale auto-update.
    WARNING: an auto-update will replace these patched binaries with the
    official Windows 10+ build.

.PARAMETER NoPath
    Do not add the installation directory to the system PATH.

.PARAMETER NoShortcuts
    Do not create Start Menu / Startup shortcuts.

.PARAMETER NoAcl
    Do not apply the MSI's install/state directory ACLs.

.PARAMETER SkipPrereqCheck
    Skip Windows 7 hotfix detection (KB2921916 / SHA-2 updates).

.PARAMETER DryRun
    Log every action without changing the system.

.PARAMETER StartGui
    Start tailscale-ipn.exe after installation. By default the GUI is not
    started because an elevated installer would launch it as administrator;
    use the Start Menu shortcut instead.

.PARAMETER LogPath
    Installer log file. Default: %TEMP%\tailscale-win7-install.log

.PARAMETER PauseOnExit
    Wait for Enter before closing. Used when the script self-elevates.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$NoGui,
    [switch]$NoStart,
    [switch]$PreInstallWintun,
    [switch]$KeepAutoUpdate,
    [switch]$NoPath,
    [switch]$NoShortcuts,
    [switch]$NoAcl,
    [switch]$SkipPrereqCheck,
    [switch]$DryRun,
    [switch]$StartGui,
    [string]$LogPath = '',
    [switch]$PauseOnExit
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and logging
# ---------------------------------------------------------------------------

$script:ScriptPath = (Resolve-Path -LiteralPath $MyInvocation.MyCommand.Definition).Path
$script:ScriptDir = Split-Path -Parent $script:ScriptPath
if (-not $LogPath) {
    $LogPath = Join-Path $env:TEMP 'tailscale-win7-install.log'
}

function Initialize-InstallerLog {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    ('===== Tailscale 1.104.7 Windows 7/8 installer =====') |
        Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}

try {
    Initialize-InstallerLog $LogPath
    $script:LogPath = $LogPath
} catch {
    # The elevated process may run as a different administrator account and
    # may not be able to write the caller's log path.
    $fallback = Join-Path $env:TEMP 'tailscale-win7-install.log'
    try {
        Initialize-InstallerLog $fallback
        $LogPath = $fallback
        $script:LogPath = $fallback
    } catch {
        $fallback = Join-Path $env:SystemRoot 'Temp\tailscale-win7-install.log'
        Initialize-InstallerLog $fallback
        $LogPath = $fallback
        $script:LogPath = $fallback
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $line = ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message)
    Write-Host $line
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {
    }
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'ERROR'
    if ($PauseOnExit) {
        Read-Host 'Press Enter to close' | Out-Null
    }
    exit 1
}

Write-Log ('Package directory: ' + $script:ScriptDir)
Write-Log ('Log file:          ' + $script:LogPath)

if ([IntPtr]::Size -eq 4 -and $env:ProgramW6432 -and -not $DryRun) {
    Fail 'This installer must run under 64-bit PowerShell. Run install-win7.cmd, or use C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.'
}

# ---------------------------------------------------------------------------
# Native helpers (export probe + environment broadcast)
# ---------------------------------------------------------------------------

$nativeCode = @'
using System;
using System.Runtime.InteropServices;

public static class TsWin7Native
{
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetModuleHandleA(string name);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);

    public static bool HasExport(string module, string name)
    {
        IntPtr h = GetModuleHandleA(module);
        if (h == IntPtr.Zero)
            return false;
        return GetProcAddress(h, name) != IntPtr.Zero;
    }

    public static void BroadcastEnvironmentChange()
    {
        UIntPtr result;
        SendMessageTimeout(new IntPtr(0xffff), 0x001A, UIntPtr.Zero,
            "Environment", 0x0002, 5000, out result);
    }
}
'@

try {
    if (-not ('TsWin7Native' -as [type])) {
        Add-Type -TypeDefinition $nativeCode -ErrorAction Stop
    }
} catch {
    Fail ('Could not compile the native helper: ' + $_.Exception.Message)
}

function Test-Kernel32Export {
    param([string]$Name)
    return [TsWin7Native]::HasExport('kernel32.dll', $Name)
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-Admin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($DryRun) {
        Write-Log 'Not elevated; continuing because -DryRun was specified.' 'WARN'
    } else {
        Write-Log 'Administrator privileges are required; relaunching elevated...' 'WARN'
        $scriptPath = $script:ScriptPath
        if ($scriptPath.StartsWith('\\')) {
            Fail 'The package is running from a network share. Copy it to a local folder (for example C:\Temp) and run it again.'
        }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $scriptPath + '"'))
        if ($InstallDir) {
            $argList += '-InstallDir'
            $argList += ('"' + $InstallDir + '"')
        }
        if ($NoGui) { $argList += '-NoGui' }
        if ($NoStart) { $argList += '-NoStart' }
        if ($PreInstallWintun) { $argList += '-PreInstallWintun' }
        if ($KeepAutoUpdate) { $argList += '-KeepAutoUpdate' }
        if ($NoPath) { $argList += '-NoPath' }
        if ($NoShortcuts) { $argList += '-NoShortcuts' }
        if ($NoAcl) { $argList += '-NoAcl' }
        if ($SkipPrereqCheck) { $argList += '-SkipPrereqCheck' }
        if ($StartGui) { $argList += '-StartGui' }
        if ($LogPath) {
            $argList += '-LogPath'
            $argList += ('"' + $LogPath + '"')
        }
        $argList += '-PauseOnExit'
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
            exit 0
        } catch {
            Fail ('Could not elevate: ' + $_.Exception.Message + '. Right-click install-win7.cmd and choose "Run as administrator".')
        }
    }
}

# ---------------------------------------------------------------------------
# OS checks
# ---------------------------------------------------------------------------

try {
    $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
    $osVersion = [Version]$os.Version
    $osCaption = $os.Caption
    $osArch = $os.OSArchitecture
} catch {
    Fail ('Could not query the operating system version: ' + $_.Exception.Message)
}

Write-Log ('OS: {0} {1} ({2})' -f $osCaption, $osVersion, $osArch)

if ($osArch -ne '64-bit') {
    Fail 'This package requires 64-bit Windows.'
}
if ($osVersion.Major -lt 6 -or ($osVersion.Major -eq 6 -and $osVersion.Minor -lt 1)) {
    Fail 'Windows 7 SP1 or later is required.'
}
if ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 1 -and $osVersion.Build -lt 7601) {
    Fail 'Windows 7 Service Pack 1 (build 7601) is required.'
}

$isWin7 = ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 1)

if ($osVersion.Major -ge 10) {
    Write-Log 'Windows 10 or newer detected. The official Tailscale MSI is recommended; this package also works.' 'WARN'
}

# ---------------------------------------------------------------------------
# Install directory and payload checks
# ---------------------------------------------------------------------------

if (-not $InstallDir) {
    $programFiles = $env:ProgramW6432
    if (-not $programFiles) {
        $programFiles = $env:ProgramFiles
    }
    $InstallDir = Join-Path $programFiles 'Tailscale'
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
if ($InstallDir.Length -gt 3) {
    $InstallDir = $InstallDir.TrimEnd('\')
}
if ($InstallDir.Length -le 3) {
    Fail 'InstallDir must not be the root of a drive.'
}
if ($InstallDir.StartsWith('\\')) {
    Fail 'InstallDir must be a local path; services cannot run from a network share.'
}

$programData = $env:ProgramData
if (-not $programData) {
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
}
$StateDir = Join-Path $programData 'Tailscale'

$requiredFiles = @('tailscaled.exe', 'tailscale.exe', 'wintun.dll', 'uninstall-win7.ps1')
if (-not $NoGui) {
    $requiredFiles += 'tailscale-ipn.exe'
    $requiredFiles += 'tsbcryptprng_win.dll'
}
foreach ($file in $requiredFiles) {
    $path = Join-Path $script:ScriptDir $file
    if (-not (Test-Path -LiteralPath $path)) {
        Fail ('Required package file not found: ' + $path)
    }
}

# ---------------------------------------------------------------------------
# Hotfix detection (Windows 7)
# ---------------------------------------------------------------------------

function Test-Hotfix {
    param([string]$Id)

    $cmd = Get-Command Get-HotFix -ErrorAction SilentlyContinue
    if ($cmd) {
        $hf = Get-HotFix -Id $Id -ErrorAction SilentlyContinue
        if ($hf) {
            return $true
        }
    }

    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
    if (Test-Path -LiteralPath $cbs) {
        $found = $false
        Get-ChildItem -Path $cbs -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSChildName -like ('*' + $Id + '*')) {
                $found = $true
            }
        }
        if ($found) {
            return $true
        }
    }

    $uninstall = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    if (Test-Path -LiteralPath $uninstall) {
        $found = $false
        Get-ChildItem -Path $uninstall -ErrorAction SilentlyContinue | ForEach-Object {
            $displayName = (Get-ItemProperty -Path $_.PSPath -Name DisplayName -ErrorAction SilentlyContinue).DisplayName
            if ($displayName -and $displayName -like ('*' + $Id + '*')) {
                $found = $true
            }
        }
        if ($found) {
            return $true
        }
    }

    return $false
}

# The patched GUI is built with the stock Go 1.27 runtime and needs
# LOAD_LIBRARY_SEARCH_APPLICATION_DIR (KB2533623 on Windows 7).
$kb2533623 = $true
if ($isWin7) {
    $kb2533623 = Test-Kernel32Export 'SetDefaultDllDirectories'
}

$skipGui = [bool]$NoGui
if (-not $skipGui -and $isWin7 -and -not $kb2533623) {
    Write-Log 'KB2533623 is not installed. The patched GUI requires it; installing the service and CLI only.' 'WARN'
    Write-Log 'Install KB2533623 (or a later Windows 7 rollup), reboot, then run this installer again to add the GUI.' 'WARN'
    $skipGui = $true
}

if ($isWin7 -and -not $SkipPrereqCheck) {
    if (-not (Test-Hotfix 'KB2921916')) {
        Write-Log 'KB2921916 was not detected. Without it, Wintun driver installation may show an untrusted-publisher prompt or fail.' 'WARN'
        Write-Log 'The x64 hotfix is bundled in the prereq folder; install it, reboot, and rerun this installer if the driver fails.' 'WARN'
    }
    if (-not (Test-Hotfix 'KB4474419')) {
        Write-Log 'KB4474419 (SHA-2 support) was not detected. The signed Wintun driver may fail to install.' 'WARN'
    }
    if (-not (Test-Hotfix 'KB3033929')) {
        Write-Log 'KB3033929 (SHA-2 code signing) was not detected. The signed Wintun driver may fail to install.' 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Required Windows services
# ---------------------------------------------------------------------------

$dependencyNames = @('Dnscache', 'iphlpsvc', 'netprofm', 'WinHttpAutoProxySvc')
$badDependencies = @()
foreach ($dependency in $dependencyNames) {
    $wmiService = Get-WmiObject -Class Win32_Service -Filter ("Name='" + $dependency + "'") -ErrorAction SilentlyContinue
    if (-not $wmiService) {
        $badDependencies += ($dependency + ' (missing)')
    } elseif ($wmiService.StartMode -eq 'Disabled') {
        $badDependencies += ($dependency + ' (disabled)')
    }
}
if ($badDependencies.Count -gt 0) {
    Fail ('These Windows services are required by Tailscale but are unavailable: ' +
        ($badDependencies -join ', ') + '. Enable them and run the installer again.')
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Set-DirectorySddl {
    param(
        [string]$Path,
        [string]$Sddl
    )
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm($Sddl)
    Set-Acl -Path $Path -AclObject $acl
}

function Copy-Payload {
    param([string]$Name)
    $source = Join-Path $script:ScriptDir $Name
    $destination = Join-Path $InstallDir $Name
    if ($DryRun) {
        Write-Log ('DRY RUN: copy {0} -> {1}' -f $source, $destination)
        return
    }
    if (Test-Path -LiteralPath $destination) {
        try {
            (Get-Item -LiteralPath $destination).IsReadOnly = $false
        } catch {
        }
    }
    try {
        Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
    } catch {
        Fail ('Could not copy ' + $Name + ' to ' + $destination + ': ' + $_.Exception.Message +
            '. Close Tailscale (including the tray icon), confirm the Tailscale service is stopped, then retry.')
    }
    try {
        [System.IO.File]::Delete($destination + ':Zone.Identifier')
    } catch {
    }
    Write-Log ('Copied ' + $Name)
}

function New-TailscaleShortcut {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$WorkingDirectory,
        [string]$IconPath
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = ($IconPath + ',0')
    $shortcut.Description = 'Tailscale'
    $shortcut.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Stop-TailscaleService {
    $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }
    if ($service.Status -eq 'Stopped') {
        return
    }
    Write-Log 'Stopping existing Tailscale service...'
    if ($DryRun) {
        Write-Log 'DRY RUN: sc.exe stop Tailscale'
        return
    }
    & sc.exe stop Tailscale | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $current = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
        if (-not $current -or $current.Status -eq 'Stopped') {
            break
        }
        Start-Sleep -Seconds 1
    }
    $current = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($current -and $current.Status -ne 'Stopped') {
        Write-Log ('Service did not stop (status: ' + $current.Status + '); retrying.') 'WARN'
        & sc.exe stop Tailscale | Out-Null
        Start-Sleep -Seconds 3
    }
}

function Stop-TailscaleGui {
    $processes = Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue
    if (-not $processes) {
        return
    }
    foreach ($process in $processes) {
        Write-Log ('Stopping Tailscale GUI (pid ' + $process.Id + ')...')
        if ($DryRun) {
            continue
        }
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            Write-Log ('Could not stop GUI pid ' + $process.Id + ': ' + $_.Exception.Message) 'WARN'
        }
    }
    if (-not $DryRun) {
        Start-Sleep -Seconds 2
    }
}

# ---------------------------------------------------------------------------
# Existing official MSI installation
# ---------------------------------------------------------------------------

$stockMsi = $false
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($root in $uninstallRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }
    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        $item = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($item -and $item.DisplayName -eq 'Tailscale' -and
            $item.UninstallString -match 'msiexec') {
            $stockMsi = $true
        }
    }
}
if ($stockMsi) {
    Write-Log 'An official Tailscale MSI installation was detected. This package replaces its binaries but does not unregister the MSI.' 'WARN'
    Write-Log 'For a clean setup, uninstall the official Tailscale from Programs and Features first, then run this installer again.' 'WARN'
}

# ---------------------------------------------------------------------------
# Stop existing processes
# ---------------------------------------------------------------------------

Stop-TailscaleGui
Stop-TailscaleService

# ---------------------------------------------------------------------------
# Directories and ACLs
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Log ('DRY RUN: create directory ' + $InstallDir)
    Write-Log ('DRY RUN: create directory ' + $StateDir)
} else {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    Write-Log ('Install directory: ' + $InstallDir)
    Write-Log ('State directory:   ' + $StateDir)
}

if (-not $NoAcl) {
    $installSddl = 'D:PAI(A;;FA;;;SY)(A;OICIIO;GA;;;SY)(A;;FA;;;BA)(A;OICIIO;GA;;;BA)(A;;FRFX;;;BU)(A;OICIIO;GRGX;;;BU)'
    $stateSddl = 'D:PAI(A;;FA;;;SY)(A;OICIIO;GA;;;SY)(A;;FA;;;BA)(A;OICIIO;GA;;;BA)'
    if ($DryRun) {
        Write-Log ('DRY RUN: set install directory ACL: ' + $installSddl)
        Write-Log ('DRY RUN: set state directory ACL: ' + $stateSddl)
    } else {
        try {
            Set-DirectorySddl -Path $InstallDir -Sddl $installSddl
            Write-Log 'Applied install directory ACL.'
        } catch {
            Write-Log ('Could not apply install directory ACL: ' + $_.Exception.Message) 'WARN'
        }
        try {
            Set-DirectorySddl -Path $StateDir -Sddl $stateSddl
            Write-Log 'Applied state directory ACL.'
        } catch {
            Write-Log ('Could not apply state directory ACL: ' + $_.Exception.Message) 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------

Copy-Payload 'tailscaled.exe'
Copy-Payload 'tailscale.exe'
Copy-Payload 'wintun.dll'
Copy-Payload 'uninstall-win7.ps1'
if (Test-Path -LiteralPath (Join-Path $script:ScriptDir 'README-WIN7.md')) {
    Copy-Payload 'README-WIN7.md'
}
if (-not $skipGui) {
    Copy-Payload 'tailscale-ipn.exe'
    Copy-Payload 'tsbcryptprng_win.dll'
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

$serviceName = 'Tailscale'
$serviceExe = Join-Path $InstallDir 'tailscaled.exe'
$serviceBinPath = '"' + $serviceExe + '"'
$serviceDependencies = 'Dnscache/iphlpsvc/netprofm/WinHttpAutoProxySvc'

$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($DryRun) {
    if ($existingService) {
        Write-Log ('DRY RUN: sc.exe config ' + $serviceName + ' binPath= ' + $serviceBinPath + ' start= auto depend= ' + $serviceDependencies)
    } else {
        Write-Log ('DRY RUN: sc.exe create ' + $serviceName + ' binPath= ' + $serviceBinPath + ' type= own start= auto error= normal DisplayName= Tailscale depend= ' + $serviceDependencies)
    }
    Write-Log ('DRY RUN: sc.exe description ' + $serviceName + ' "Connects this computer to others on the Tailscale network."')
} else {
    if (-not $existingService) {
        Write-Log 'Creating Tailscale service...'
        & sc.exe create $serviceName binPath= $serviceBinPath type= own start= auto error= normal DisplayName= Tailscale depend= $serviceDependencies | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail ('sc.exe create failed with exit code ' + $LASTEXITCODE + '.')
        }
    } else {
        Write-Log 'Updating existing Tailscale service...'
        $configured = $false
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            & sc.exe config $serviceName binPath= $serviceBinPath start= auto depend= $serviceDependencies DisplayName= Tailscale | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $configured = $true
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $configured) {
            Fail ('sc.exe config failed with exit code ' + $LASTEXITCODE + '. The service may be marked for deletion; reboot and retry.')
        }
    }

    & sc.exe description $serviceName 'Connects this computer to others on the Tailscale network.' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log ('sc.exe description failed with exit code ' + $LASTEXITCODE + '.') 'WARN'
    }
}

# Service security descriptor from the MSI's MsiLockPermissionsEx table.
# The SACL requires SeSecurityPrivilege; fall back to the DACL if refused.
$serviceSddl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RP;;;BU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)'
$serviceDacl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RP;;;BU)'

if ($DryRun) {
    Write-Log ('DRY RUN: sc.exe sdset ' + $serviceName + ' ' + $serviceSddl)
    Write-Log ('DRY RUN: sc.exe failure ' + $serviceName + ' reset= 60 actions= restart/1000/restart/2000/restart/4000/restart/9000/restart/16000/restart/25000/restart/36000/restart/49000/restart/64000')
} else {
    & sc.exe sdset $serviceName $serviceSddl | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'Could not set the full service security descriptor (SACL refused); trying DACL only.' 'WARN'
        & sc.exe sdset $serviceName $serviceDacl | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'Could not set the service DACL; leaving the default service ACL.' 'WARN'
        } else {
            Write-Log 'Set service DACL.'
        }
    } else {
        Write-Log 'Set service security descriptor.'
    }

    & sc.exe failure $serviceName reset= 60 actions= restart/1000/restart/2000/restart/4000/restart/9000/restart/16000/restart/25000/restart/36000/restart/49000/restart/64000 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log ('sc.exe failure failed with exit code ' + $LASTEXITCODE + '.') 'WARN'
    } else {
        Write-Log 'Configured service failure actions.'
    }
}

# ---------------------------------------------------------------------------
# Registry (Tailscale IPN key, URL handler)
# ---------------------------------------------------------------------------

$guiPath = Join-Path $InstallDir 'tailscale-ipn.exe'

if ($DryRun) {
    Write-Log 'DRY RUN: remove legacy NSIS registry keys'
    Write-Log 'DRY RUN: write HKLM\SOFTWARE\Tailscale IPN (default, GUIPath, MSI, Shortcuts)'
    if (-not $skipGui) {
        Write-Log 'DRY RUN: write HKCR\tailscale URL handler and HKCR\*\shell\tailscale'
    }
} else {
    # Legacy NSIS (Tailscale 1.44.3 and older) cleanup, mirroring the MSI's
    # UpgradeFromNSIS component.
    foreach ($legacyKey in @(
        'SOFTWARE\WOW6432Node\Tailscale IPN',
        'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Tailscale IPN')) {
        try {
            [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($legacyKey, $false)
        } catch {
        }
    }

    $ipnKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Tailscale IPN')
    try {
        $ipnKey.DeleteValue('seed', $false)
    } catch {
    }
    $ipnKey.SetValue('', ($InstallDir + '\'), [Microsoft.Win32.RegistryValueKind]::String)
    if (Test-Path -LiteralPath $guiPath) {
        $ipnKey.SetValue('GUIPath', $guiPath, [Microsoft.Win32.RegistryValueKind]::String)
    } else {
        $ipnKey.DeleteValue('GUIPath', $false)
    }
    $ipnKey.SetValue('MSI', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    $ipnKey.SetValue('Shortcuts', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    $ipnKey.Close()
    Write-Log 'Wrote HKLM\SOFTWARE\Tailscale IPN.'

    if (-not $skipGui) {
        $classes = [Microsoft.Win32.Registry]::ClassesRoot

        $urlKey = $classes.CreateSubKey('tailscale')
        $urlKey.SetValue('', 'URL:Tailscale Protocol', [Microsoft.Win32.RegistryValueKind]::String)
        $urlKey.SetValue('URL Protocol', '', [Microsoft.Win32.RegistryValueKind]::String)
        $urlKey.Close()

        $iconKey = $classes.CreateSubKey('tailscale\DefaultIcon')
        $iconKey.SetValue('', ('"' + $guiPath + '",1'), [Microsoft.Win32.RegistryValueKind]::String)
        $iconKey.Close()

        $commandKey = $classes.CreateSubKey('tailscale\shell\open\command')
        $commandKey.SetValue('', ('"' + $guiPath + '" /url "%1"'), [Microsoft.Win32.RegistryValueKind]::String)
        $commandKey.Close()

        $taildropKey = $classes.CreateSubKey('*\shell\tailscale')
        $taildropKey.Close()

        Write-Log 'Wrote Tailscale URL handler registry keys.'
    }
}

# ---------------------------------------------------------------------------
# Auto-update policy
# ---------------------------------------------------------------------------

if (-not $KeepAutoUpdate) {
    if ($DryRun) {
        Write-Log 'DRY RUN: set HKLM\SOFTWARE\Policies\Tailscale CheckUpdates=never, InstallUpdates=never'
    } else {
        $policyKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Policies\Tailscale')
        $policyKey.SetValue('CheckUpdates', 'never', [Microsoft.Win32.RegistryValueKind]::String)
        $policyKey.SetValue('InstallUpdates', 'never', [Microsoft.Win32.RegistryValueKind]::String)
        $policyKey.Close()
        Write-Log 'Disabled Tailscale auto-update via machine policy.'
    }
}

# ---------------------------------------------------------------------------
# System PATH
# ---------------------------------------------------------------------------

if (-not $NoPath) {
    $environmentKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    if ($DryRun) {
        Write-Log ('DRY RUN: append ' + $InstallDir + ' to the system PATH if missing')
    } else {
        $environmentKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($environmentKeyPath, $true)
        if (-not $environmentKey) {
            Write-Log 'Could not open the system environment registry key; PATH was not updated.' 'WARN'
        } else {
            $oldPath = [string]$environmentKey.GetValue(
                'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $parts = @()
            $wasPresent = $false
            $removedStale = $false
            if ($oldPath) {
                foreach ($part in $oldPath.Split(';')) {
                    $trimmed = $part.Trim()
                    if ($trimmed -eq '') {
                        continue
                    }
                    if ($trimmed.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) {
                        if (-not $wasPresent) {
                            $parts += $InstallDir
                            $wasPresent = $true
                        }
                        continue
                    }
                    if ($trimmed.TrimEnd('\') -imatch '\\Tailscale IPN$') {
                        $removedStale = $true
                        continue
                    }
                    $parts += $trimmed
                }
            }
            if (-not $wasPresent) {
                $parts += $InstallDir
            }
            $newPath = $parts -join ';'
            if ($newPath -ne $oldPath) {
                $environmentKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $changes = @()
                if (-not $wasPresent) {
                    $changes += 'added the install directory'
                }
                if ($removedStale) {
                    $changes += 'removed a stale Tailscale IPN entry'
                }
                if ($changes.Count -eq 0) {
                    $changes += 'normalized the entry list'
                }
                Write-Log ('System PATH updated: ' + ($changes -join '; ') + '.')
                [TsWin7Native]::BroadcastEnvironmentChange()
            } else {
                Write-Log 'System PATH is already correct.'
            }
            $environmentKey.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# Shortcuts
# ---------------------------------------------------------------------------

if (-not $NoShortcuts -and -not $skipGui) {
    $startMenu = Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) 'Programs'
    $startup = [Environment]::GetFolderPath('CommonStartup')
    $startMenuLink = Join-Path $startMenu 'Tailscale.lnk'
    $startupLink = Join-Path $startup 'Tailscale.lnk'

    if ($DryRun) {
        Write-Log ('DRY RUN: create shortcut ' + $startMenuLink)
        Write-Log ('DRY RUN: create shortcut ' + $startupLink)
    } else {
        try {
            New-TailscaleShortcut -LinkPath $startMenuLink -TargetPath $guiPath -WorkingDirectory $InstallDir -IconPath $guiPath
            New-TailscaleShortcut -LinkPath $startupLink -TargetPath $guiPath -WorkingDirectory $InstallDir -IconPath $guiPath
            Write-Log 'Created Start Menu and Startup shortcuts.'
        } catch {
            Write-Log ('Could not create shortcuts: ' + $_.Exception.Message) 'WARN'
        }

        foreach ($oldName in @('Tailscale Mesh.lnk')) {
            foreach ($folder in @($startMenu, $startup)) {
                $oldPath = Join-Path $folder $oldName
                if (Test-Path -LiteralPath $oldPath) {
                    Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
                    Write-Log ('Removed old shortcut ' + $oldPath)
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Per-user avatar directory (MSI Avatars component)
# ---------------------------------------------------------------------------

if (-not $skipGui) {
    if ($DryRun) {
        Write-Log ('DRY RUN: create ' + (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Tailscale\Avatars'))
    } else {
        try {
            $avatarDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Tailscale\Avatars'
            if (-not (Test-Path -LiteralPath $avatarDir)) {
                New-Item -ItemType Directory -Path $avatarDir -Force | Out-Null
            }
        } catch {
            Write-Log ('Could not create the per-user avatar directory: ' + $_.Exception.Message) 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# Optional Wintun driver preinstall
# ---------------------------------------------------------------------------

if ($PreInstallWintun) {
    $driverInf = Join-Path (Join-Path $script:ScriptDir 'driver') 'wintun.inf'
    if (-not (Test-Path -LiteralPath $driverInf)) {
        Write-Log ('Wintun driver files not found at ' + $driverInf + '; skipping preinstall.') 'WARN'
    } elseif ($DryRun) {
        Write-Log ('DRY RUN: pnputil -a ' + $driverInf)
    } else {
        $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
        if (-not (Test-Path -LiteralPath $pnputil)) {
            Write-Log 'pnputil.exe not found; skipping Wintun preinstall.' 'WARN'
        } else {
            Write-Log 'Staging the Wintun driver package...'
            & $pnputil -a $driverInf 2>&1 | ForEach-Object { Write-Log ([string]$_) }
            if ($LASTEXITCODE -ne 0) {
                Write-Log ('pnputil returned ' + $LASTEXITCODE + '; Wintun will install the driver on demand when the adapter is created.') 'WARN'
            } else {
                Write-Log 'Wintun driver package staged.'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Add/Remove Programs entry
# ---------------------------------------------------------------------------

$arpKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\TailscaleWin7'
if ($DryRun) {
    Write-Log 'DRY RUN: write Add/Remove Programs entry TailscaleWin7'
} else {
    $estimatedSize = 0
    foreach ($file in @('tailscaled.exe', 'tailscale.exe', 'tailscale-ipn.exe', 'wintun.dll', 'tsbcryptprng_win.dll')) {
        $path = Join-Path $InstallDir $file
        if (Test-Path -LiteralPath $path) {
            $estimatedSize += [int]((Get-Item -LiteralPath $path).Length / 1024)
        }
    }
    $uninstallScript = Join-Path $InstallDir 'uninstall-win7.ps1'
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $uninstallCommand = '"' + $powershellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $uninstallScript + '"'

    $arpKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($arpKeyPath)
    $arpKey.SetValue('DisplayName', 'Tailscale (Windows 7/8 build)', [Microsoft.Win32.RegistryValueKind]::String)
    $arpKey.SetValue('DisplayVersion', '1.104.7', [Microsoft.Win32.RegistryValueKind]::String)
    $arpKey.SetValue('Publisher', 'Tailscale Inc.', [Microsoft.Win32.RegistryValueKind]::String)
    $arpKey.SetValue('InstallLocation', $InstallDir, [Microsoft.Win32.RegistryValueKind]::String)
    if (Test-Path -LiteralPath $guiPath) {
        $arpKey.SetValue('DisplayIcon', $guiPath, [Microsoft.Win32.RegistryValueKind]::String)
    } else {
        $arpKey.SetValue('DisplayIcon', $serviceExe, [Microsoft.Win32.RegistryValueKind]::String)
    }
    $arpKey.SetValue('UninstallString', $uninstallCommand, [Microsoft.Win32.RegistryValueKind]::String)
    $arpKey.SetValue('NoModify', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    $arpKey.SetValue('NoRepair', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    $arpKey.SetValue('EstimatedSize', $estimatedSize, [Microsoft.Win32.RegistryValueKind]::DWord)
    $arpKey.SetValue('InstallDate', (Get-Date -Format 'yyyyMMdd'), [Microsoft.Win32.RegistryValueKind]::String)
    $arpKey.Close()
    Write-Log 'Wrote Add/Remove Programs entry.'
}

# ---------------------------------------------------------------------------
# Start service / GUI
# ---------------------------------------------------------------------------

if (-not $NoStart) {
    if ($DryRun) {
        Write-Log 'DRY RUN: sc.exe start Tailscale'
    } else {
        Write-Log 'Starting Tailscale service...'
        & sc.exe start Tailscale | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log ('sc.exe start returned ' + $LASTEXITCODE + '. Check the service log under ' + (Join-Path $StateDir 'Logs') + '.') 'WARN'
        } else {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
                if ($service -and $service.Status -eq 'Running') {
                    break
                }
                Start-Sleep -Seconds 1
            }
            $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Write-Log 'Tailscale service is running.'
            } else {
                $status = 'not found'
                if ($service) {
                    $status = [string]$service.Status
                }
                Write-Log ('Tailscale service status: ' + $status) 'WARN'
            }
        }
    }
}

if ($StartGui -and -not $skipGui) {
    if ($DryRun) {
        Write-Log ('DRY RUN: start ' + $guiPath)
    } else {
        try {
            Start-Process -FilePath $guiPath -WorkingDirectory $InstallDir | Out-Null
            Write-Log 'Started Tailscale GUI.'
        } catch {
            Write-Log ('Could not start the GUI: ' + $_.Exception.Message) 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Log 'Installation complete.'
Write-Log ('Install directory: ' + $InstallDir)
Write-Log ('State directory:   ' + $StateDir)
Write-Log ('Log file:          ' + $LogPath)

if ($skipGui) {
    if ($NoGui) {
        Write-Log 'GUI was skipped because -NoGui was specified.' 'WARN'
    } else {
        Write-Log 'GUI was skipped because KB2533623 is missing. Install it, reboot, and rerun this installer to add the GUI.' 'WARN'
    }
    Write-Log 'Use the CLI, for example: tailscale up'
} else {
    Write-Log 'Launch Tailscale from the Start Menu, or run: tailscale up'
    Write-Log 'Do not use the GUI update button; auto-update is disabled to protect these patched binaries.'
}

if ($PauseOnExit) {
    Read-Host 'Press Enter to close' | Out-Null
}
exit 0
