# Tailscale 1.104.7 for Windows 7, 8, and 8.1 (x64)

This package is an **unofficial compatibility build** of Tailscale 1.104.7 for
64-bit Windows 7 SP1, Windows 8, and Windows 8.1. The official 1.104.7 installer
requires Windows 10 or newer, and Tailscale stopped supporting Windows 7 after
version 1.44.3.

The service and CLI are rebuilt from the open-source Tailscale tree with a
Windows 7-compatible Go toolchain. The closed-source GUI is binary-patched. The
service/CLI are the supported path in this package; the GUI is best-effort on
Windows 7/8.

> **Use at your own risk.** Windows 7 and 8 are out of support and no longer
> receive security fixes. This build is not produced or supported by Tailscale
> Inc. Keep the machine off untrusted networks, or better, upgrade it.

---

## Package contents

| File | Purpose |
| --- | --- |
| `tailscaled.exe` | Tailscale service, rebuilt for Windows 7/8 |
| `tailscale.exe` | Tailscale CLI, rebuilt for Windows 7/8 |
| `tailscale-ipn.exe` | Patched Tailscale GUI |
| `tsbcryptprng_win.dll` | App-local `ProcessPrng` shim used by the GUI on Windows 7 |
| `wintun.dll` | Wintun 0.14.1 userspace VPN adapter library |
| `install-win7.ps1` / `.cmd` | Installer |
| `uninstall-win7.ps1` / `.cmd` | Uninstaller |
| `driver\wintun.{inf,sys,cat}` | Wintun driver package for optional preinstall |
| `prereq\Windows6.1-KB2921916-x64.msu` | Microsoft Windows 7 driver-prompt hotfix |
| `SHA256SUMS.txt` | File hashes |
| `README-WIN7.md` | This document |

Only the x64 build is provided. There is no 32-bit build.

### Verifying the files

`SHA256SUMS.txt` lists the SHA-256 hash of every file in this package. To check
one file on Windows 7:

```bat
certutil -hashfile tailscaled.exe SHA256
```

Compare the output with the matching line in `SHA256SUMS.txt`. On newer Windows
versions you can also use `Get-FileHash -Algorithm SHA256 <file>`.

---

## Requirements

### All systems

- 64-bit Windows 7 SP1, Windows 8, or Windows 8.1.
- Administrator rights.
- PowerShell 2.0 or newer (included with Windows 7).
- The package extracted to a **local** folder. Do not run it from a network
  share; the Windows service cannot run from a UNC path.

### Windows 7 SP1 additional updates

Install these before using Tailscale, then reboot:

1. **KB2533623** — adds `SetDefaultDllDirectories`,
   `AddDllDirectory`, and the `LOAD_LIBRARY_SEARCH_*` flags.
   The patched GUI requires it. The service/CLI have a fallback, but installing
   the update is still recommended.
   - If it is missing, `install-win7.ps1` installs the service and CLI only and
     tells you to install the update and rerun the installer for the GUI.
2. **KB2921916** — prevents the "untrusted publisher" dialog when Windows
   installs the Wintun driver. The x64 `.msu` is bundled in `prereq\`.
   Tailscale's own Windows 7 page lists this as required.
3. **KB4474419** and **KB3033929** — SHA-2 hashing and code-signing support.
   The Wintun driver is SHA-2 signed. Without these updates, Windows 7 may
   reject the driver.
   - On a fresh Windows 7 SP1 install, install the servicing-stack update
     **KB4490628** first, then KB4474419, then reboot.
4. All available Windows 7 rollups/updates, if practical.

Windows 8/8.1 include the loader APIs and SHA-2 support; the Windows 7 updates
above are not needed there. Windows 8.1 may still need current root certificate
updates for driver signature validation.

### Driver signing

Do **not** disable driver signature enforcement and do **not** enable test
mode. Wintun 0.14.1 is properly signed; the Windows 7 updates above are the
correct fix if the driver will not install.

---

## Installation

1. Extract the whole package to a local folder, for example `C:\Temp\ts-win7`.
2. Right-click **`install-win7.cmd`** and choose **Run as administrator**.
   - Or, from an elevated PowerShell prompt:
     ```powershell
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-win7.ps1
     ```
3. The installer self-elevates if needed. Review the log at
   `%TEMP%\tailscale-win7-install.log`.
4. Reboot if you installed a Windows 7 update or the Wintun driver during the
   install.

### Installer options

```text
-InstallDir <path>     Install directory (default: %ProgramFiles%\Tailscale)
-NoGui                 Install the service and CLI only
-NoStart               Do not start the service after installation
-PreInstallWintun      Stage the Wintun driver with pnputil
-KeepAutoUpdate        Do not disable Tailscale auto-update (not recommended)
-NoPath                Do not add the install directory to the system PATH
-NoShortcuts           Do not create Start Menu / Startup shortcuts
-NoAcl                 Do not apply the MSI directory ACLs
-SkipPrereqCheck       Skip Windows 7 hotfix detection
-DryRun                Log actions without changing the system
-StartGui              Start the GUI after installation
-LogPath <path>        Installer log path
```

Examples:

```powershell
# Service/CLI only, no GUI
.\install-win7.ps1 -NoGui

# Install to a custom directory and pre-stage the Wintun driver
.\install-win7.ps1 -InstallDir 'D:\Apps\Tailscale' -PreInstallWintun

# Preview what would happen
.\install-win7.ps1 -DryRun
```

### What the installer does

The installer mirrors the official MSI's machine-level behavior:

- Creates `%ProgramFiles%\Tailscale` and `%ProgramData%\Tailscale`.
- Applies the MSI's install-directory ACL (SYSTEM/Administrators full control,
  Users read/execute) and state-directory ACL (SYSTEM/Administrators full
  control).
- Copies the patched binaries and the app-local `tsbcryptprng_win.dll` shim.
- Creates the `Tailscale` service:
  - display name `Tailscale`, own-process, auto-start, LocalSystem;
  - dependencies `Dnscache`, `iphlpsvc`, `netprofm`, `WinHttpAutoProxySvc`;
  - description "Connects this computer to others on the Tailscale network.";
  - the MSI's service security descriptor;
  - restart-on-failure actions (1s, 2s, 4s, 9s, 16s, 25s, 36s, 49s, 64s;
    60-second reset period).
- Writes `HKLM\SOFTWARE\Tailscale IPN` (`MSI=1`, `Shortcuts=1`, `GUIPath`,
  install path hint).
- Registers the `tailscale://` URL handler and the Taildrop shell key.
- Adds the install directory to the **system** `PATH`.
- Creates Start Menu and Startup shortcuts.
- Creates an Add/Remove Programs entry named
  **Tailscale (Windows 7/8 build)**.
- Disables auto-update via machine policy (see below).

If an existing Tailscale service is present, the installer stops it, replaces
the binaries, and reconfigures the service. The node state in
`%ProgramData%\Tailscale` is preserved.

---

## First use

### CLI (recommended)

Open a new Command Prompt or PowerShell window so the updated `PATH` is visible:

```bat
tailscale up
```

The command prints a login URL. Open it in a browser and authenticate. Then:

```bat
tailscale status
tailscale ip -4
tailscale ping <peer-name-or-ip>
```

To log out and remove this node's identity:

```bat
tailscale logout
```

### GUI

Launch **Start Menu → Tailscale**, or the Startup shortcut created for all
users. The GUI needs `tsbcryptprng_win.dll` in the same directory as
`tailscale-ipn.exe`; do not delete or move that DLL.

The GUI is closed source and was patched as a binary. It is expected to work on
Windows 7/8, but it has not been tested on every Windows 7/8 build. If it fails
to start, use the CLI; the service and CLI provide the full networking
functionality.

---

## Verification

```bat
sc query Tailscale
tailscale version
tailscale status
ipconfig /all
```

Expected:

- `sc query Tailscale` reports `RUNNING`.
- `tailscale version` reports `1.104.7` and a long version ending in `-win7`.
- `tailscale status` lists this machine and peers.
- `ipconfig /all` shows a `Tailscale` network adapter with a `100.x.y.z`
  address once the node is logged in and up.

Service log files are under `%ProgramData%\Tailscale\Logs`.

---

## Auto-update is disabled

An official Tailscale update would replace these patched binaries with the
Windows 10+ build and break the installation. The installer therefore writes:

```text
HKLM\SOFTWARE\Policies\Tailscale
    CheckUpdates   REG_SZ   never
    InstallUpdates REG_SZ   never
```

Do not use the GUI's update button, and do not install an official Tailscale
MSI/EXE over this build. To update, obtain a newer Windows 7-compatible build
from whoever produced this package.

If you must re-enable updates (not recommended), delete those two values:

```powershell
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Tailscale' CheckUpdates, InstallUpdates
```

---

## Upgrading or repairing

Run `install-win7.cmd` again. The installer is idempotent: it stops the service,
replaces the files, reapplies the service configuration and ACLs, and starts the
service. The node identity is kept.

If you are upgrading from the last official Windows 7 release (1.44.3) or an
older NSIS/MSI install:

1. Uninstall the old version first if possible.
2. Remove any leftover `C:\Program Files\Tailscale IPN` directory. (The
   installer removes the legacy `HKLM\SOFTWARE\WOW6432Node\Tailscale IPN` key
   automatically.)
3. Run this installer.

If the official 1.104.7 MSI is installed (it only installs on Windows 10+),
uninstall it from **Programs and Features** before running this installer. The
installer detects it and warns, but it cannot unregister the MSI. Leaving the
MSI registered means a repair, upgrade, or uninstall of the official package
can overwrite or remove these patched binaries.

The installer reuses the existing service name and state directory. If an old
Tailscale service is still installed, the installer stops it and reconfigures
it to use the new binaries. Uninstalling the old version first avoids mixed
files, stale registry entries, and a leftover uninstaller.

---

## Uninstallation

Right-click **`uninstall-win7.cmd`** and choose **Run as administrator**, or use
**Control Panel → Programs and Features → Tailscale (Windows 7/8 build)**.

By default the uninstaller **keeps** `%ProgramData%\Tailscale` (node identity,
certificates, logs). To remove it as well:

```powershell
.\uninstall-win7.ps1 -RemoveState
```

To ask Tailscale to remove the Wintun driver and network adapter:

```powershell
.\uninstall-win7.ps1 -RemoveWintunDriver
```

If driver removal fails, open **Device Manager → Network adapters**, right-click
the `Tailscale` adapter, and uninstall it. The driver package can also be removed
with `pnputil` from an elevated prompt.

Other uninstaller options:

```text
-InstallDir <path>     Override the detected install directory
-RemoveState           Delete %ProgramData%\Tailscale
-RemoveWintunDriver    Run tailscale-ipn.exe /uninstallwintun first
-DryRun                Log actions without changing the system
-LogPath <path>        Uninstaller log path
```

The uninstaller log is `%TEMP%\tailscale-win7-uninstall.log`.

---

## Troubleshooting

### The service does not start

1. Check `%ProgramData%\Tailscale\Logs` and Event Viewer →
   Windows Logs → System/Application.
2. Confirm the four dependency services are running or enabled:
   ```bat
   sc qc Tailscale
   sc query Dnscache
   sc query iphlpsvc
   sc query netprofm
   sc query WinHttpAutoProxySvc
   ```
3. On Windows 7, confirm KB2533623, KB2921916, KB4474419, and KB3033929 are
   installed, then reboot.
4. Try starting the service manually:
   ```bat
   sc start Tailscale
   ```
5. A `TPM: error opening: TBS Error 0x8028400F` line in the log is non-fatal;
   Tailscale continues without TPM-backed state encryption.

### The Wintun driver or adapter fails

- Install the Windows 7 updates listed above and reboot.
- Run the installer again with `-PreInstallWintun`.
- Check **Device Manager → Network adapters** for a `Tailscale` device with a
  warning icon.
- Do not disable driver signature enforcement; fix the SHA-2 updates instead.
- If the adapter exists but is stale, remove it in Device Manager and restart
  the service.

### DNS does not work

On Windows 7, Tailscale's DNS integration uses a pre-NRPT fallback path. If name
resolution is broken, first try disabling Tailscale DNS:

```bat
tailscale up --accept-dns=false
```

Then use IP addresses or your normal DNS configuration. Please report the
Windows 7 build and the `%ProgramData%\Tailscale\Logs` contents if you need this
fixed.

### The GUI does not start

- Confirm KB2533623 is installed on Windows 7.
- Confirm `tsbcryptprng_win.dll` is next to `tailscale-ipn.exe`.
- Try launching it from an elevated prompt to see the error:
  ```bat
  "C:\Program Files\Tailscale\tailscale-ipn.exe"
  ```
- If it still fails, use the CLI. The service and CLI do not depend on the GUI.

### `tailscale up` says access denied

Run the command from an elevated prompt, or check that the `Tailscale` service is
running and that the current user can open the service pipe. The GUI normally
runs as the logged-in user and connects to the service; the CLI may need
elevation on some Windows 7 configurations.

### SmartScreen or "Windows protected your PC"

The rebuilt binaries are unsigned. On Windows 8/8.1, right-click the file →
Properties → **Unblock**, or run:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

`Unblock-File` requires PowerShell 3.0. On Windows 7, the installer removes the
Mark-of-the-Web from the files it copies.

### The installer says a required Windows service is disabled

Enable the named service (for example `iphlpsvc` or `WinHttpAutoProxySvc`) in
`services.msc`, set it to Manual or Automatic, and run the installer again.

---

## Technical notes

### Service and CLI

- Rebuilt from the Tailscale 1.104.7 source tree with the
  `go-legacy-win7` Go 1.27.4 fork.
- PE `MajorOperatingSystemVersion` / `MajorSubsystemVersion` are 6.1, so the
  binaries load on Windows 7.
- `net/dns/manager_windows.go`: the NRPT catch-all rule is skipped when the
  NRPT database is unavailable, which is the case on Windows 7.
- The `wingoes` dependency accepts pre-Windows-10 versions and uses
  `VerifyVersionInfoW` for Windows 10 build queries instead of panicking.
- The Go runtime and `syscall` loader fall back to loading system DLLs by full
  path if `LOAD_LIBRARY_SEARCH_SYSTEM32` is rejected on Windows 7 without
  KB2533623.
- Only `kernel32.dll` is a static import. There are no Windows 8/10-only static
  imports.

### GUI

The GUI is closed source. The following binary patches were applied:

- PE `MajorOperatingSystemVersion` / `MajorSubsystemVersion`: 10.0 → 6.1.
- `wingoes.(*osVersionInfo).init`: the two `major == 10` / `minor == 0`
  rejection branches are NOPed, so pre-Windows-10 versions fall through to the
  normal version-string path.
- Runtime and `syscall` DLL loader flags: `0x800`
  (`LOAD_LIBRARY_SEARCH_SYSTEM32`) → `0xA00`
  (`LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR`), so
  the app-local shim is found without writing to `System32`.
- `bcryptprimitives.dll` → `tsbcryptprng_win.dll` (exactly 20 characters, no NUL
  padding). The shim exports `ProcessPrng` and forwards to the real
  `bcryptprimitives!ProcessPrng` when available (Windows 8+), otherwise to
  `advapi32!SystemFunction036` (`RtlGenRandom`). It is safe on Windows 10+ too.
- The shim is compiled without the C runtime. It imports only
  `kernel32!GetProcAddress`, `kernel32!LoadLibraryW`, and
  `kernel32!InitOnceExecuteOnce`, so it does **not** require the Universal CRT
  (KB2999226) on Windows 7.
- The shim must stay beside `tailscale-ipn.exe`. The GUI's loader flags search
  the application directory first.

### Wintun

- Wintun 0.14.1, x64. The DLL creates the adapter and installs its signed driver
  on demand. `wintun.sys` declares subsystem 6.1 and the INF has no OS floor.
- The `driver\` files are only needed for `-PreInstallWintun`; normal operation
  uses `wintun.dll`.

### MSI fidelity

The installer's service SDDL, failure actions, directory ACLs, registry values,
URL handler, shortcuts, and PATH behavior were extracted from
`tailscale-setup-1.104.7-amd64.msi`. The official MSI's only explicit OS gate is
`OSMAJORVERSION = "#10"`; the official GUI and MSI custom actions are not
Windows 7-compatible, which is why this package uses a scripted installer
instead of a patched MSI.

### Known limitations

- The GUI is binary-patched and not exhaustively tested on Windows 7/8.
- The binaries are unsigned. SmartScreen may warn on Windows 8/8.1.
- No 32-bit build.
- Tailscale DNS on Windows 7 uses a fallback path and may need
  `--accept-dns=false` on some configurations.
- Windows 7/8 no longer receive security updates. This package does not change
  that.

---

## Licenses

- Tailscale is licensed under the BSD 3-Clause License. The rebuilt binaries
  contain Tailscale and Go code.
- Wintun is licensed under the GPL 2.0 with a special exception for use with
  non-GPL software; see the Wintun project for details.
- The bundled Microsoft hotfix is subject to Microsoft's license terms.
- This package is not affiliated with or endorsed by Tailscale Inc.
