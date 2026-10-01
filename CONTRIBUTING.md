# Contributing to LanSpot

Thanks for your interest. This document covers how to get the project running
and what we expect from a change.

## Prerequisites

| Tool | Version |
| --- | --- |
| Flutter | 3.11+ (Dart 3.5+) |
| Windows | 10 / 11, x64 |
| PowerShell | 5.1+ (ships with Windows) |

No other tooling is required. LanSpot has **no third-party runtime
dependencies** — the entire UI is Flutter's own `ChangeNotifier`, and the
backend is a PowerShell helper shipped in `assets/`.

## Getting set up

```bash
flutter pub get
flutter analyze          # must be clean
flutter test             # must be green
flutter build windows --release
```

The release binary lands at
`build/windows/x64/runner/Release/LanSpot.exe`.

### Running the app

Tethering changes are Windows-level operations, and the app will try to
self-elevate when it needs administrator rights. Launch it through Explorer so
the elevation handshake behaves:

```powershell
Start-Process explorer.exe -ArgumentList "build\windows\x64\runner\Release\LanSpot.exe"
```

Launching the `.exe` directly from a shell whose integrity level is lower than
the target can break that elevation, which is why the Explorer indirection
matters when you are testing.

## Code layout

| Path | Responsibility |
| --- | --- |
| `lib/main.dart` | All UI and application state. Single screen, `ChangeNotifier`. |
| `lib/models.dart` | `HotspotMode`, `HotspotStatus`, `QuickState`, `HotspotClient`, payload parsing. |
| `lib/hotspot_service.dart` | Helper process lifecycle and the loopback socket IPC client. |
| `lib/prefs.dart` | Synchronous settings load/save. |
| `lib/theme.dart` | `Tokens`, `TokensScope`, `buildTheme`. |
| `assets/hotspot_helper.ps1` | The entire backend. WinRT tethering, `netsh` firewall, ARP lookup. |
| `test/` | `models_test.dart` (parsing), `ui_test.dart` (widgets), `hotspot_service_test.dart` (end-to-end against real Windows). |

## The two rules that matter most

**1. Never invent Windows' hotspot configuration.**

`HotspotManager.ConfigureAccessPointAsync` performs a **full replacement** of
the access point configuration, not a patch. Any field you omit or send empty
is overwritten. This is why `_toggleHotspot` sends only the fields the user
explicitly edited, and why `_adoptLiveConfig` skips dirty fields and never
clears the dirty flag on its own. If you touch settings code, preserve that
contract or you will silently wipe users' passphrases.

**2. Never block on the helper for anything the UI polls.**

The backend is a PowerShell process, and a cold `status` call can take ~14s.
Anything on the render path must come from the `quick` payload (6–17ms warm),
which is served by a *separate* helper process from the one handling long
actions. Adding a heavy call to the poll path, or sharing one helper between
polls and actions, will make the whole UI stutter.

## Tests

- `test/models_test.dart` and `test/ui_test.dart` are pure and fast.
- `test/hotspot_service_test.dart` is a real end-to-end test against the live
  Windows tethering APIs. It **toggles real hardware state** and leaves the
  hotspot as it found it. Do not run it while you are actively using your
  phone's hotspot.

`flutter_test`'s `testWidgets` runs inside a fake-async zone, so any real I/O
must be wrapped in `tester.runAsync`. That is also why `Prefs` is deliberately
synchronous.

## Commit and PR conventions

- `flutter analyze` clean and `flutter test` green are required.
- Keep the commit history readable: one logical change per commit.
- If a change touches `assets/hotspot_helper.ps1`, say so in the PR. It is the
  backend and is not covered by Dart unit tests.
- Note anything you observed on real hardware. Tethering behaviour is heavily
  driver- and OEM-dependent, and "works on my machine" is a real category of
  evidence here.

## Reporting bugs

Open an issue with:

- Windows build number (`winver`)
- Wi-Fi adapter model and driver version
- The Activity log from inside the app (there is a copy button for exactly this)
- Whether the hotspot was On or Off, and which mode

## Security

Do not open a public issue for a vulnerability. See `SECURITY.md`.
