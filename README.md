# Tailscale 1.104.7 for Windows 7 / 8 / 8.1 (x64)

Unofficial compatibility build of Tailscale 1.104.7 that runs on 64-bit
Windows 7 SP1, Windows 8, and Windows 8.1. The official 1.104.7 installer
requires Windows 10 or newer.

- `tailscaled.exe` and `tailscale.exe` are rebuilt from the Tailscale 1.104.7
  source with the `go-legacy-win7` Go 1.27.4 toolchain.
- `tailscale-ipn.exe` (the closed-source GUI) is binary-patched.
- A small CRT-free shim provides `ProcessPrng` on Windows 7.
- Wintun 0.14.1 provides the VPN adapter.

**Not affiliated with or supported by Tailscale Inc. Windows 7/8 are out of
support. Use at your own risk.**

## Quick start

1. Download `tailscale-1.104.7-win7-amd64.zip` from the Releases page (or use
   the files under `out/windows-amd64/`).
2. Extract it to a local folder (not a network share).
3. Right-click `install-win7.cmd` and choose **Run as administrator**.
4. Reboot if you installed a Windows 7 update or the Wintun driver.

Full instructions, requirements, and troubleshooting:
[`out/windows-amd64/README-WIN7.md`](out/windows-amd64/README-WIN7.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `out/windows-amd64/` | Ready-to-use package: binaries, shim, Wintun, installer/uninstaller, docs, hashes |
| `tools/` | Scripts used to patch the GUI and inspect PE files and MSI tables |
| `shim/` | Source and build script for `tsbcryptprng_win.dll` |
| `vendor/wingoes/` | Patched `github.com/dblohm7/wingoes` module used by the rebuild |
| `patches/` | Source patches applied to Tailscale and wingoes |
| `docs/msi_tables.txt` | MSI table dump used to mirror service, registry, ACL, and PATH behavior |

The Go toolchain, upstream Tailscale source tree, official MSI, and build logs
are not committed: they are large and reproducible.

## What was changed

### Service and CLI (rebuilt)

- Built with `go-legacy-win7` 1.27.4, which emits PE
  `MajorOperatingSystemVersion`/`MajorSubsystemVersion` 6.1 and falls back
  from `bcryptprimitives!ProcessPrng` to `RtlGenRandom`.
- `patches/0001-dns-skip-nrpt-catchall-without-nrptdb.patch`: skip the NRPT
  catch-all rule when the NRPT database is unavailable (Windows 7/8).
- `patches/0002-wingoes-accept-pre-win10.patch`: wingoes accepts pre-Windows-10
  versions instead of panicking.

### GUI (binary-patched)

`tools/patch_gui.py` applies:

- PE `OSVersion`/`SubsystemVersion` 10.0 to 6.1.
- NOP the two wingoes pre-Windows-10 panic branches.
- Loader flags `0x800` to `0xA00` so the app-local shim is searched.
- Rename `bcryptprimitives.dll` to `tsbcryptprng_win.dll` (exactly 20 chars).

`shim/tsbcryptprng.c` exports `ProcessPrng` and forwards to the real
`bcryptprimitives!ProcessPrng` when present, otherwise to
`advapi32!SystemFunction036`. It is compiled without the CRT
(`shim/build_crtfree.bat`).

## Verification

- PE headers: all loadable binaries report OS 6.1 / subsystem 6.1 and import
  only `kernel32.dll`.
- `out/windows-amd64/SHA256SUMS.txt` covers every payload file; the packaged
  zip was extracted and all 14 hashes re-verified.
- The patched GUI was smoke-tested on a Windows 10 host: it loads the shim,
  creates its window, and stays up; the shim's Windows 7 fallback was tested
  separately.
- Installer and uninstaller parse under PowerShell 2.0 syntax rules and pass
  `-DryRun`.

## Limitations

- No real Windows 7/8 hardware or VM was available for testing. The service
  and CLI are the reliable path; the GUI is best-effort.
- The rebuilt binaries are unsigned.
- Auto-update is disabled by policy; an official MSI must be uninstalled
  before using this package.
- No 32-bit build.

## Package hash

```text
dc6c5ebdc491e1b898f67d5a646776e8ff62a0eb82348980ad63d11ab5e418a5  tailscale-1.104.7-win7-amd64.zip
```

## Licenses

Tailscale is BSD-3-Clause; wingoes is BSD-3-Clause; Wintun is GPL-2.0 with a
non-GPL exception; the bundled Microsoft hotfix is under Microsoft's terms.
