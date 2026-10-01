# LanSpot

Windows mobile hotspot control. Turn your PC into a Wi‑Fi hotspot, switch between Normal and No Internet modes, see connected devices in real time, and block devices per‑MAC with targeted Windows Defender Firewall rules. Minimal, premium light‑mode UI with a live marching border while background work runs.

## Features

- **Two modes.** Normal shares your internet; No Internet runs the hotspot without upstream internet (clients stay offline).
- **Real‑time state.** Hotspot status, Wi‑Fi radio, and connected clients update live.
- **Per‑device blocking.** Block individual devices via the Windows Defender Firewall (the block list is the firewall). Unblock any device or clear the whole list.
- **Settings follow Windows.** Edits are tracked per field and only changed values are pushed to Windows. Starting the hotspot never overwrites your existing SSID/passphrase/band unless you edit them.
- **Resilient IPC.** Backend runs as a persistent PowerShell helper over a loopback TCP socket. The app opens the port, the helper connects back.
- **Fast + main helpers.** Two persistent helper processes keep a 6–17ms `quick` poll separate from heavier operations.
- **Marching busy border.** Indicates background work by marching dashes along the window border.
- **Activity log with copy.** Copy logs and errors for diagnostics.
- **Light‑mode first.** Premium, minimal UI with optional dark mode. |

Extras: set the network name / password / band, pick which no-internet
connection the offline mode shares from, stop Windows from switching the
hotspot off when nobody is connected, and turn your own Wi-Fi radio off from
the app.

The settings fields are a live view of what Windows has, not a second copy of
it. Change the name in the Windows Settings app and this one follows. Only
fields you actually edit get pushed back, and *Apply now* stays disabled until
you edit something, so a stray click cannot rewrite the WPA version, the
password, or the band.

## Running it

```
flutter build windows --release
```

The exe lands in `build\windows\x64\runner\Release\hotspot_control.exe`. It asks
for administrator rights on launch (it creates firewall rules and drives the
Windows tethering API), and re-launches itself elevated once you approve.

## How it works

`assets/hotspot_helper.ps1` does all the real work, one action per process:

- **Starting and stopping the hotspot** goes through
  `Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager`, the
  same WinRT API the Settings app uses.
- **"No internet"** is a pair of Windows Firewall rules. The first blocks the
  hotspot subnet (`192.168.137.0/24` by default) from leaving through the
  shared adapter. The second blocks anything on the Wi-Fi Direct adapter that
  is not aimed at the hotspot subnet, which covers the case where ICS rewrites
  the source address before the first rule is evaluated. Traffic to the PC's
  own DHCP and DNS is deliberately left open so devices still connect and show
  "connected, no internet".
- **"Offline hotspot"** shares from a connection that has no internet, for
  example the Hyper-V adapter `vEthernet (Default Switch)` or
  `Bluetooth Network Connection`. Windows refuses to start a hotspot with no
  source at all, so one of these is required. The app lists whatever it finds.

Everything the helper discovers is looked up by adapter *description* at
runtime, because Windows renumbers the `Local Area Connection* N` aliases and
keeps several `Wi-Fi Direct Virtual Adapter` instances around between reboots.

### Why not the usual `netsh wlan` trick?

Your Intel AX211 driver reports `Hosted network supported: No`, so
`netsh wlan set hostednetwork` and tools built on it (MyPublicWiFi and friends)
do not work on this machine. That is why the app uses the WinRT tethering API
instead.

## Tests

```
flutter test
```

`test/hotspot_service_test.dart` runs the real helper end to end: it unpacks the
script from the app assets, runs it and parses the reply.

## Requirements

- Windows 11 with a Wi-Fi adapter that supports hosting a hotspot
- Windows PowerShell 5.1 (present on every Windows install)
- No extra runtimes, no .NET SDK, no third party packages