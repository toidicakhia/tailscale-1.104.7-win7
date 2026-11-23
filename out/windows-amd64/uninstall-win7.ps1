#requires -Version 2.0
<#
.SYNOPSIS
    Uninstalls the Tailscale 1.104.7 Windows 7/8 compatibility build.

.DESCRIPTION
    Stops the service and GUI, removes the service, shortcuts, registry keys,
    system PATH entry, and installed files. The node state under
    %ProgramData%\Tailscale is kept by default; pass -RemoveState to delete it.

.PARAMETER InstallDir
    Installation directory. If omitted, it is read from
    HKLM\SOFTWARE\Tailscale IPN, then defaults to %ProgramW6432%\Tailscale.

.PARAMETER RemoveState
    Also delete %ProgramData%\Tailscale (node identity, certificates, logs).

.PARAMETER RemoveWintunDriver
    Ask tailscale-ipn.exe to remove the Wintun driver/adapter before deleting
    the files. If this fails, remove the "Tailscale" network adapter from
    Device Manager manually.

.PARAMETER DryRun
    Log every action without changing the system.

.PARAMETER LogPath
    Uninstaller log file. Default: %TEMP%\tailscale-win7-uninstall.log

.PARAMETER PauseOnExit
    Wait for Enter before closing. Used when the script self-elevates.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$RemoveState,
    [switch]$RemoveWintunDriver,
    [switch]$DryRun,
    [string]$LogPath = '',
    [switch]$PauseOnExit
)

$ErrorActionPreference = 'Stop'

$script:ScriptPath = (Resolve-Path -LiteralPath $MyInvocation.MyCommand.Definition).Path
$script:ScriptDir = Split-Path -Parent $script:ScriptPath

# Avoid locking the install directory as the current directory.
try {
    Set-Location -Path $env:TEMP -ErrorAction Stop
} catch {
}

if (-not $LogPath) {
    $LogPath = Join-Path $env:TEMP 'tailscale-win7-uninstall.log'
}

function Initialize-UninstallerLog {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    ('===== Tailscale 1.104.7 Windows 7/8 uninstaller =====') |
        Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}

try {
    Initialize-UninstallerLog $LogPath
    $script:LogPath = $LogPath
} catch {
    $fallback = Join-Path $env:TEMP 'tailscale-win7-uninstall.log'
    try {
        Initialize-UninstallerLog $fallback
        $LogPath = $fallback
        $script:LogPath = $fallback
    } catch {
        $fallback = Join-Path $env:SystemRoot 'Temp\tailscale-win7-uninstall.log'
        Initialize-UninstallerLog $fallback
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

Write-Log ('Log file: ' + $script:LogPath)

if ([IntPtr]::Size -eq 4 -and $env:ProgramW6432 -and -not $DryRun) {
    Fail 'This uninstaller must run under 64-bit PowerShell. Run uninstall-win7.cmd, or use C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.'
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
            Fail 'The uninstaller is running from a network share. Copy it to a local folder and run it again.'
        }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $scriptPath + '"'))
        if ($InstallDir) {
            $argList += '-InstallDir'
            $argList += ('"' + $InstallDir + '"')
        }
        if ($RemoveState) { $argList += '-RemoveState' }
        if ($RemoveWintunDriver) { $argList += '-RemoveWintunDriver' }
        if ($LogPath) {
            $argList += '-LogPath'
            $argList += ('"' + $LogPath + '"')
        }
        $argList += '-PauseOnExit'
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
            exit 0
        } catch {
            Fail ('Could not elevate: ' + $_.Exception.Message + '. Right-click the uninstaller and choose "Run as administrator".')
        }
    }
}

# ---------------------------------------------------------------------------
# Native helper for WM_SETTINGCHANGE
# ---------------------------------------------------------------------------

$nativeCode = @'
using System;
using System.Runtime.InteropServices;

public static class TsWin7UninstallNative
{
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);

    public static void BroadcastEnvironmentChange()
    {
        UIntPtr result;
        SendMessageTimeout(new IntPtr(0xffff), 0x001A, UIntPtr.Zero,
            "Environment", 0x0002, 5000, out result);
    }
}
'@

try {
    if (-not ('TsWin7UninstallNative' -as [type])) {
        Add-Type -TypeDefinition $nativeCode -ErrorAction Stop
    }
} catch {
    Fail ('Could not compile the native helper: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# Resolve install directory
# ---------------------------------------------------------------------------

if (-not $InstallDir) {
    $ipnKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Tailscale IPN')
    if ($ipnKey) {
        $hint = [string]$ipnKey.GetValue('', '')
        $ipnKey.Close()
        if ($hint) {
            $InstallDir = $hint.TrimEnd('\')
        }
    }
}
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
    Fail 'Refusing to uninstall from the root of a drive.'
}

$programData = $env:ProgramData
if (-not $programData) {
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
}
$StateDir = Join-Path $programData 'Tailscale'
$guiPath = Join-Path $InstallDir 'tailscale-ipn.exe'

Write-Log ('Install directory: ' + $InstallDir)
Write-Log ('State directory:   ' + $StateDir)

# ---------------------------------------------------------------------------
# Stop GUI
# ---------------------------------------------------------------------------

$guiProcesses = Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue
if ($guiProcesses) {
    foreach ($process in $guiProcesses) {
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
# Remove Wintun driver (while the service is still available)
# ---------------------------------------------------------------------------

if ($RemoveWintunDriver) {
    if (Test-Path -LiteralPath $guiPath) {
        if ($DryRun) {
            Write-Log ('DRY RUN: "' + $guiPath + '" /uninstallwintun')
        } else {
            Write-Log 'Asking Tailscale to remove the Wintun driver and adapter...'
            try {
                $process = Start-Process -FilePath $guiPath -ArgumentList '/uninstallwintun' -WorkingDirectory $InstallDir -PassThru
                $deadline = (Get-Date).AddSeconds(60)
                while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 1
                    $process.Refresh()
                }
                if (-not $process.HasExited) {
                    try {
                        $process.Kill()
                    } catch {
                    }
                    Write-Log 'Timed out waiting for /uninstallwintun.' 'WARN'
                } else {
                    Write-Log ('/uninstallwintun exited with code ' + $process.ExitCode + '.')
                    if ($process.ExitCode -ne 0) {
                        Write-Log 'The Wintun driver may still be installed; check Device Manager.' 'WARN'
                    }
                }
            } catch {
                Write-Log ('Could not run /uninstallwintun: ' + $_.Exception.Message) 'WARN'
            }
        }
    } else {
        Write-Log 'tailscale-ipn.exe not found; cannot remove the Wintun driver automatically.' 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Stop and delete the service
# ---------------------------------------------------------------------------

$service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne 'Stopped') {
        Write-Log 'Stopping Tailscale service...'
        if ($DryRun) {
            Write-Log 'DRY RUN: sc.exe stop Tailscale'
        } else {
            & sc.exe stop Tailscale | Out-Null
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $current = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
                if (-not $current -or $current.Status -eq 'Stopped') {
                    break
                }
                Start-Sleep -Seconds 1
            }
        }
    }

    if ($DryRun) {
        Write-Log 'DRY RUN: sc.exe delete Tailscale'
    } else {
        Write-Log 'Deleting Tailscale service...'
        & sc.exe delete Tailscale | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log ('sc.exe delete returned ' + $LASTEXITCODE + '.') 'WARN'
        }
        for ($attempt = 0; $attempt -lt 15; $attempt++) {
            $current = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
            if (-not $current) {
                break
            }
            Start-Sleep -Seconds 1
        }
    }
} else {
    Write-Log 'Tailscale service is not installed.'
}

# ---------------------------------------------------------------------------
# Shortcuts
# ---------------------------------------------------------------------------

$startMenu = Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) 'Programs'
$startup = [Environment]::GetFolderPath('CommonStartup')
foreach ($folder in @($startMenu, $startup)) {
    foreach ($name in @('Tailscale.lnk', 'Tailscale Mesh.lnk')) {
        $link = Join-Path $folder $name
        if (Test-Path -LiteralPath $link) {
            if ($DryRun) {
                Write-Log ('DRY RUN: remove ' + $link)
            } else {
                Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
                Write-Log ('Removed ' + $link)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Add/Remove Programs entry
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Log 'DRY RUN: remove Add/Remove Programs entry TailscaleWin7'
} else {
    try {
        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree(
            'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\TailscaleWin7', $false)
        Write-Log 'Removed Add/Remove Programs entry.'
    } catch {
        Write-Log ('Could not remove the Add/Remove Programs entry: ' + $_.Exception.Message) 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Registry keys
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Log 'DRY RUN: remove HKLM\SOFTWARE\Tailscale IPN'
    Write-Log 'DRY RUN: remove HKCR\tailscale and HKCR\*\shell\tailscale'
} else {
    try {
        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree('SOFTWARE\Tailscale IPN', $false)
        Write-Log 'Removed HKLM\SOFTWARE\Tailscale IPN.'
    } catch {
        Write-Log ('Could not remove HKLM\SOFTWARE\Tailscale IPN: ' + $_.Exception.Message) 'WARN'
    }
    try {
        [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree('tailscale', $false)
        Write-Log 'Removed HKCR\tailscale.'
    } catch {
        Write-Log ('Could not remove HKCR\tailscale: ' + $_.Exception.Message) 'WARN'
    }
    try {
        [Microsoft.Win32.Registry]::ClassesRoot.DeleteSubKeyTree('*\shell\tailscale', $false)
        Write-Log 'Removed HKCR\*\shell\tailscale.'
    } catch {
        Write-Log ('Could not remove HKCR\*\shell\tailscale: ' + $_.Exception.Message) 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Auto-update policy values (keep unrelated policy values)
# ---------------------------------------------------------------------------

$policyKey = $null
if ($DryRun) {
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Tailscale') {
        Write-Log 'DRY RUN: remove CheckUpdates / InstallUpdates policy values'
    }
} else {
    $policyKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Policies\Tailscale', $true)
}
if ($policyKey) {
    $otherValues = @()
    foreach ($name in $policyKey.GetValueNames()) {
        if ($name -ne 'CheckUpdates' -and $name -ne 'InstallUpdates') {
            $otherValues += $name
        }
    }
    if ($otherValues.Count -eq 0) {
        $policyKey.Close()
        try {
            [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree('SOFTWARE\Policies\Tailscale', $false)
            Write-Log 'Removed Tailscale policy key.'
        } catch {
            Write-Log ('Could not remove the Tailscale policy key: ' + $_.Exception.Message) 'WARN'
        }
    } else {
        foreach ($name in @('CheckUpdates', 'InstallUpdates')) {
            try {
                $policyKey.DeleteValue($name, $false)
            } catch {
            }
        }
        $policyKey.Close()
        Write-Log 'Removed auto-update policy values; other policy values were kept.'
    }
}

# ---------------------------------------------------------------------------
# System PATH
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Log ('DRY RUN: remove ' + $InstallDir + ' from the system PATH')
} else {
    $environmentKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    if ($environmentKey) {
        $oldPath = [string]$environmentKey.GetValue(
            'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $newParts = @()
        if ($oldPath) {
            foreach ($part in $oldPath.Split(';')) {
                if ($part.Trim() -eq '') {
                    continue
                }
                if ($part.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) {
                    continue
                }
                $newParts += $part
            }
        }
        $newPath = $newParts -join ';'
        if ($newPath -ne $oldPath) {
            $environmentKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Log 'Removed install directory from the system PATH.'
            [TsWin7UninstallNative]::BroadcastEnvironmentChange()
        } else {
            Write-Log 'Install directory was not present in the system PATH.'
        }
        $environmentKey.Close()
    } else {
        Write-Log 'Could not open the system environment registry key; PATH was not changed.' 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Per-user avatar directory
# ---------------------------------------------------------------------------

$userStateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Tailscale'
if (Test-Path -LiteralPath $userStateDir) {
    if ($DryRun) {
        Write-Log ('DRY RUN: remove ' + $userStateDir)
    } else {
        try {
            Remove-Item -LiteralPath $userStateDir -Recurse -Force -ErrorAction Stop
            Write-Log ('Removed ' + $userStateDir)
        } catch {
            Write-Log ('Could not remove ' + $userStateDir + ': ' + $_.Exception.Message) 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# Install directory
# ---------------------------------------------------------------------------

if (Test-Path -LiteralPath $InstallDir) {
    $looksLikeInstall = $false
    foreach ($marker in @('tailscaled.exe', 'tailscale.exe', 'tailscale-ipn.exe')) {
        if (Test-Path -LiteralPath (Join-Path $InstallDir $marker)) {
            $looksLikeInstall = $true
            break
        }
    }
    if (-not $looksLikeInstall) {
        Write-Log ($InstallDir + ' does not contain a Tailscale installation; refusing to delete it.') 'WARN'
    } elseif ($DryRun) {
        Write-Log ('DRY RUN: remove ' + $InstallDir)
    } else {
        $removed = $false
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
                $removed = $true
                break
            } catch {
                Start-Sleep -Seconds 2
            }
        }
        if ($removed) {
            Write-Log ('Removed ' + $InstallDir)
        } else {
            Write-Log ('Could not remove ' + $InstallDir + '. Reboot, then delete the folder manually.') 'WARN'
        }
    }
} else {
    Write-Log 'Install directory is already gone.'
}

# ---------------------------------------------------------------------------
# State directory
# ---------------------------------------------------------------------------

if (Test-Path -LiteralPath $StateDir) {
    if ($RemoveState) {
        if ($DryRun) {
            Write-Log ('DRY RUN: remove ' + $StateDir)
        } else {
            try {
                Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction Stop
                Write-Log ('Removed ' + $StateDir)
            } catch {
                Write-Log ('Could not remove ' + $StateDir + ': ' + $_.Exception.Message) 'WARN'
            }
        }
    } else {
        Write-Log ('Kept state directory ' + $StateDir + ' (node identity, certificates, logs).')
        Write-Log 'Pass -RemoveState to delete it.'
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Log 'Uninstallation complete.'
Write-Log ('Log file: ' + $LogPath)
if (-not $RemoveState) {
    Write-Log ('State kept at: ' + $StateDir)
}

if ($PauseOnExit) {
    Read-Host 'Press Enter to close' | Out-Null
}
exit 0
