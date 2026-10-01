# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| < 1.0 | No |

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security problem.**

Use GitHub's private reporting instead: go to the Security tab on the
repository and choose **Report a vulnerability**. You should get an
acknowledgement within seven days.

Please include:

- What the issue is, and what an attacker gains from it
- Steps to reproduce
- The Activity log from inside the app, if the issue involves the helper
- Your Windows build and Wi-Fi adapter model

## Threat model

LanSpot is a local desktop utility. It runs on the user's own machine and
controls the user's own hotspot. The relevant boundaries are:

**Loopback-only IPC.** The app binds a socket to `127.0.0.1` on an ephemeral
port and passes that port to the helper as a command-line argument. The helper
connects back to it. Nothing listens on an external interface. Note that any
local process can connect to the socket if it learns the port, so the channel is
protected by the OS's local-user boundary rather than by authentication.

**Administrator rights.** Toggling tethering and writing firewall rules require
elevation, and the app will self-elevate via `Start-Process -Verb RunAs` when
needed. The manifest stays `asInvoker` on purpose: elevation is requested at
runtime only, when a specific privileged operation needs it.

**Firewall rule names.** Rules LanSpot creates are prefixed `LanSpot block`
and `LanSpot client` so they can be identified and removed
cleanly. They are the block list — deleting the rules in Windows Firewall
removes the blocks.

**Settings.** Stored unencrypted at
`%AppData%\LanSpot\settings.json`. This includes the hotspot
passphrase. It is readable by any process running as your user, which on
Windows is already a high bar, but it is not encrypted at rest.

## What we consider out of scope

- Other local processes acting as your user. LanSpot trusts the local user
  boundary, as most desktop software does.
- Windows' own tethering implementation. LanSpot calls the WinRT tethering
  APIs; it does not patch or replace them.
- Physical access to an unlocked machine.
