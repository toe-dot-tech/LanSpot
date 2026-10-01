# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-01

### Added

- Normal and No Internet hotspot modes. No Internet starts the hotspot and cuts
  connected devices off from the internet using targeted Windows Firewall
  inbound-block rules.
- Real-time device list with per-device IP addresses, resolved from the neighbour
  table.
- Per-device blocking and unblocking, plus a clear-all action. The Windows
  Firewall rule set is the block list.
- Live settings that track Windows' actual access point configuration. Only
  fields the user explicitly edits are ever written back, and starting the
  hotspot never overwrites existing settings.
- Wi-Fi radio toggle that reflects state changes made outside the app, in real
  time.
- Light-mode-first interface with an optional dark theme, built on a shared
  design-token layer.
- Marching border indicator while background work is in flight, so long
  PowerShell operations never feel like a hang.
- Activity log with a copy button for diagnostics.
- Auto-start the hotspot with the app, as an opt-in preference.
- Persistent helper processes with a fast path for polling and a separate main
  process for long-running actions, so the interface stays responsive.

### Technical

- Backend is a self-contained PowerShell helper talking to the WinRT
  `NetworkOperatorTetheringManager` API, with no third-party runtime
  dependencies.
- Helper IPC uses a loopback TCP socket rather than stdin/stdout, because
  Windows PowerShell does not reliably deliver lines written to its redirected
  stdin.
- Hotspot manager, network adapter, and firewall rule lookups are cached inside
  the helper process. The fast poll answers in roughly 6–17ms warm.

### Fixed

- **No Internet mode could not start while already offline.** The helper
  selected a single upstream profile and refused to start unless it found a
  non-Wi-Fi one. On a laptop with only a Wi-Fi connection and no internet,
  there was no such profile, so the start failed. The helper now builds an
  ordered list of candidate connections and tries each in turn, including the
  Wi-Fi link itself, which is the point of this mode.
- **The Wi-Fi radio toggle lagged behind reality.** Adapter state came only from
  the 12-second full sweep. It now rides along on the 300ms `quick` payload,
  read from a rate-limited single-adapter query.

[Unreleased]: https://github.com/toe-dot-tech/LanSpot/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/toe-dot-tech/LanSpot/releases/tag/v1.0.0
