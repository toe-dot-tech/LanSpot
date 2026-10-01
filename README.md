# LanSpot

**Windows mobile hotspot control.** Turn your PC into a Wi-Fi hotspot, switch between Normal and No Internet modes, watch connected devices appear in real time, and block individual devices by MAC address.

Minimal, light-mode-first interface with a marching border that shows when Windows is still working.

## Features

- **Two modes.** *Normal* shares your internet. *No Internet* runs the hotspot with clients deliberately cut off from the internet.
- **Real-time state.** Hotspot status, the Wi-Fi radio, and connected devices update live — including changes you make in Windows Settings, not just in this app.
- **Per-device blocking.** Block a single device by MAC using targeted Windows Defender Firewall rules. Unblock one, or clear the list. The firewall *is* the block list.
- **Settings that follow Windows.** The name, password, and band fields are a live view of what Windows already has, not a second copy. Only fields you actually edit are ever written back, so a stray click cannot rewrite your passphrase or band.
- **Marching busy border.** Long PowerShell operations feel responsive because the window border animates in place while work is in flight, instead of the UI appearing to hang.
- **Activity log with copy.** One button copies logs and errors for pasting into a bug report.
- **Light mode by default**, with an optional dark theme. No unnecessary shadows or visual noise.

## Screenshots

_Coming soon._

## How it works

### WinRT tethering, not `netsh`

The backend drives `Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager` — the same WinRT API the Windows Settings app uses.

This is deliberate. The common approach (`netsh wlan set hostednetwork` and the tools built on it) does not work on modern hardware: on an Intel AX211, `netsh wlan show drivers` reports `Hosted network supported: No`, so there is no hosted network to start regardless of what the script asks for.

### No Internet mode is a firewall rule

Windows has no native way to run a hotspot while denying clients internet. LanSpot does it with two inbound-block rules on the Wi-Fi Direct adapter:

1. A rule blocking the hotspot subnet (`192.168.137.0/24` by default) from leaving through the shared adapter.
2. A rule blocking anything on the Wi-Fi Direct adapter not aimed at that subnet, which covers the case where ICS rewrites the source address before the first rule is evaluated.

Traffic to the PC's own DHCP and DNS is deliberately left open, so devices still associate and correctly report "connected, no internet".

### IPC over a loopback TCP socket

The backend is a single PowerShell script, `assets/hotspot_helper.ps1`, run as a long-lived process per channel. The app binds `127.0.0.1` on an ephemeral port and passes the port to the helper on the command line; the helper connects back and then serves newline-delimited JSON requests.

The socket exists because **Windows PowerShell does not reliably deliver lines written to its redirected stdin.** Under `-File` and `-Command`, with `runInShell`, and through `cmd /c`, `ReadLine()` on the redirected stream blocks forever. Piping works from `cmd /c` — for example `cmd /c more` reads the same pipe fine — so this is a PowerShell host quirk, not a pipe bug. Every request appeared to hang for its full timeout. A loopback socket sidesteps it entirely.

There are **two** helper processes:

| Process | Serves | Warm latency |
| --- | --- | --- |
| `fast` | `quick` polls only | 6–17 ms |
| `main` | everything else | — |

The split matters. A cold `status` call costs about 14 seconds, and a warm one runs 0.9–2.7 s. If polls shared a process with actions, a 300 ms poll would queue behind a slow action and the entire UI would stutter. Keeping the poll on its own process makes that impossible.

Inside each process the hot lookups are cached: the tethering manager, the physical Wi-Fi adapter, and the firewall rule set. Firewall work goes through `netsh` rather than `Get-NetFirewallRule`, which walks 1016 rules and costs 2.2 s warm. Client addresses come from `arp -a` (~80 ms) rather than `Get-NetNeighbor` (2.1 s cold).

### Never clobber the live configuration

`ConfigureAccessPointAsync` is a **full replacement** of the access point configuration, not a patch — every field you send wins, and omitted fields get overwritten. LanSpot therefore tracks which fields you have actually edited and sends only those. Starting the hotspot does not touch the name, password, or band at all.

This contract is the easiest thing to break in this codebase, so it is documented in `CONTRIBUTING.md` as one of two rules that must be preserved.

## Requirements

- Windows 10 or 11, x64
- A Wi-Fi adapter that supports hosting a hotspot
- Windows PowerShell 5.1 (present on every Windows install)
- Flutter 3.11+ / Dart 3.5+ to build from source

No .NET SDK, no Python, no third-party runtime packages. The only dependency is Flutter itself, used as a UI toolkit.

Administrator rights are requested at launch, because the app creates firewall rules and drives the tethering API. The executable manifest deliberately stays `asInvoker` and elevation is requested at runtime, only when a privileged operation actually needs it.

## Build

```bash
flutter pub get
flutter build windows --release
```

The binary lands at `build/windows/x64/runner/Release/LanSpot.exe`.

To run it, launch through Explorer:

```powershell
Start-Process explorer.exe -ArgumentList "build\windows\x64\runner\Release\LanSpot.exe"
```

The indirection matters when testing. Starting the `.exe` directly from a shell whose integrity level is lower than the target breaks the app's self-elevation handshake.

## Tests

```bash
flutter test
```

| Suite | What it covers |
| --- | --- |
| `test/models_test.dart` | Payload parsing, block-list handling, quick-state merge semantics |
| `test/ui_test.dart` | Widget behaviour against a fake service |
| `test/hotspot_service_test.dart` | **End-to-end against the live Windows tethering APIs** |

The end-to-end suite toggles real hardware state and restores it afterwards. It will interfere with a hotspot you are actually using, so do not run it while your phone is connected.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the two invariants you need to know before touching the settings or polling code, and [SECURITY.md](SECURITY.md) for the threat model.

## License

[MIT](LICENSE) © 2026 Emmanuel Orimoluye (TOE Tech)
