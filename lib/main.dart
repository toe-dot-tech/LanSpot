import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hotspot_service.dart';
import 'models.dart';
import 'prefs.dart';
import 'theme.dart';

/// Passed to the re-launched copy so it does not try to elevate all over again.
const String kElevatedInstanceArg = '--elevated-instance';

void main(List<String> args) {
  runApp(LanSpotApp(
    skipElevation: kDebugMode || args.contains(kElevatedInstanceArg),
  ));
}

class LanSpotApp extends StatefulWidget {
  const LanSpotApp({super.key, required this.skipElevation});

  final bool skipElevation;

  @override
  State<LanSpotApp> createState() => _LanSpotAppState();
}

class _LanSpotAppState extends State<LanSpotApp> {
  /// Loaded once here so the theme is known for the very first frame, and so the
  /// page and the title bar are writing to the same file rather than each
  /// keeping a copy.
  final Prefs _prefs = Prefs.load();

  bool get _dark => _prefs.darkMode;

  @override
  Widget build(BuildContext context) {
    final tokens = _dark ? Tokens.dark : Tokens.light;
    return MaterialApp(
      title: 'LanSpot',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tokens),
      darkTheme: buildTheme(Tokens.dark),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => TokensScope(
        tokens: TokensScope.of(context),
        child: child!,
      ),
      home: HomePage(
        skipElevation: widget.skipElevation,
        onToggleTheme: _toggleTheme,
        darkMode: _dark,
        prefs: _prefs,
      ),
    );
  }

  void _toggleTheme() {
    setState(() {
      _prefs.darkMode = !_prefs.darkMode;
      _prefs.save();
    });
  }
}

enum LogKind { info, good, warn, bad }

class LogEntry {
  LogEntry(this.text, this.kind);
  final String text;
  final LogKind kind;
  final DateTime at = DateTime.now();
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.skipElevation,
    required this.onToggleTheme,
    required this.darkMode,
    required this.prefs,
    this.service,
  });

  /// True when this instance must not re-launch itself with elevation, either
  /// because it is already elevated or because we are running under the
  /// debugger, where detaching would kill the hot reload connection.
  final bool skipElevation;

  final VoidCallback onToggleTheme;
  final bool darkMode;

  /// The settings store, owned by the app so the title bar and the page share
  /// one instance.
  final Prefs prefs;

  /// Overridable so layout can be tested without spawning PowerShell.
  final HotspotService? service;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final HotspotService _service = widget.service ?? HotspotService();

  HotspotStatus _status = HotspotStatus.empty();
  HotspotMode _mode = HotspotMode.normal;

  final TextEditingController _ssid = TextEditingController();
  final TextEditingController _password = TextEditingController();

  /// Set once Windows reports a real access point configuration. Until then the
  /// fields hold our remembered defaults, which are only ever sent on a start
  /// request - never on a live change, so we cannot clobber the user's settings
  /// with a guess.
  bool _adoptedLiveConfig = false;

  /// Per-field "the user touched this" flags. Only dirty fields are pushed to
  /// Windows, so a half-finished edit never quietly rewrites the settings the
  /// user never looked at.
  bool _ssidDirty = false;
  bool _passwordDirty = false;
  bool _bandDirty = false;

  String _band = 'Auto';
  bool _keepAlive = false;
  bool _autoStart = false;
  bool _showPassword = false;
  bool _started = false;
  bool _elevating = false;

  /// How many helper actions are in flight. It is a count rather than a flag
  /// because a mode switch and a hotspot start can overlap, and the busy frame
  /// should stay up until the last one lands.
  int _inflight = 0;

  bool get _busy => _inflight > 0;

  /// Which live list the right rail is showing: 0 devices, 1 activity.
  int _railTab = 0;

  String? _sourceHint;
  String? _lastError;
  Timer? _timer;
  Timer? _slowTimer;

  /// The mode the user has asked for while another mode change was still
  /// running. Letting the last tap win keeps the segmented control responsive
  /// instead of dropping taps that land during the slow firewall work.
  HotspotMode? _pendingMode;
  bool _modeBusy = false;

  /// Guards against a poll piling up behind another one. The fast and slow polls
  /// get their own flags and never block one another: they are answered by
  /// separate helper processes, so one being slow is no reason to starve the
  /// other.
  bool _slowBusy = false;
  bool _quickBusy = false;

  final List<LogEntry> _log = <LogEntry>[];

  final FocusNode _ssidFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _slowTimer?.cancel();
    // Stops both helper processes, so no PowerShell is left running after the
    // window closes.
    _service.dispose();
    _ssid.dispose();
    _password.dispose();
    _ssidFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> _boot() async {
    final prefs = widget.prefs;
    if (!mounted) return;

    _mode = prefs.mode;
    _band = prefs.band;
    _keepAlive = prefs.keepAlive;
    _autoStart = prefs.autoStart;
    _ssid.text = prefs.ssid;
    _password.text = prefs.password;

    _log.add(LogEntry('Ready.', LogKind.info));

    // The polling guard is opened before the first read, otherwise these calls
    // are a no-op and the screen sits on empty defaults until the first tick.
    _started = true;

    // The cheap read answers in about a second even on a cold start, so the
    // screen comes up with the live state straight away. The full sweep costs
    // several seconds and only fills in the slower details - the firewall state,
    // the blocked list - so it runs behind the UI instead of in front of it.
    await _refreshQuick();

    if (!_status.elevated && !widget.skipElevation) {
      await _requestElevation();
      return;
    }

    if (_autoStart) {
      // Auto-start needs the whole picture, because there is nothing to share
      // until a Wi-Fi adapter is up, and the user asked for this behaviour, so
      // waiting for the sweep here is the right trade.
      await _refresh();
      if (!_status.on && _status.wifiPresent) {
        _log.add(LogEntry('Auto-start is on, turning the hotspot on.', LogKind.info));
        await _toggleHotspot();
      }
    } else {
      unawaited(_refresh());
    }

    _startPolling();
  }

  /// Re-launches this app elevated, which Windows requires before we can create
  /// firewall rules or start tethering. If the user declines the prompt the app
  /// carries on without those features instead of dying.
  Future<void> _requestElevation() async {
    _say('Administrator rights are needed - waiting for the Windows prompt.', LogKind.info);
    setState(() => _elevating = true);

    const powershell = r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");

    try {
      // Start-Process with -Verb RunAs blocks until the user answers the UAC
      // prompt, so this returns as soon as we know whether they said yes.
      final result = await Process.run(
        powershell,
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Start-Process -FilePath '$exe' -ArgumentList '$kElevatedInstanceArg' -Verb RunAs",
        ],
        runInShell: false,
      );

      if (result.exitCode == 0) {
        // Give the elevated copy time to show up, then step out of the way.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        exit(0);
      }
      _say('Administrator rights were declined, so the firewall options are off.',
          LogKind.warn);
    } catch (e) {
      _say('Could not ask for administrator rights: $e', LogKind.warn);
    }

    if (!mounted) return;
    setState(() => _elevating = false);
    _started = true;
    _startPolling();
    await _refresh();
  }

  void _save() {
    widget.prefs
      ..mode = _mode
      ..ssid = _ssid.text
      ..password = _password.text
      ..band = _band
      ..keepAlive = _keepAlive
      ..autoStart = _autoStart;
    widget.prefs.save();
  }

  // ------------------------------------------------------------------ helpers

  void _say(String text, LogKind kind) {
    setState(() {
      _log.insert(0, LogEntry(text, kind));
      if (_log.length > 200) _log.removeLast();
    });
  }

  void _report(HelperResult result) {
    if (!result.ok) {
      _say(result.error!, LogKind.bad);
      setState(() => _lastError = result.error);
      return;
    }
    setState(() => _lastError = null);
    _say(result.detail, LogKind.good);
    for (final note in result.notes) {
      _say(note, LogKind.warn);
    }
  }

  /// Runs a helper action while showing the busy state and refreshing after.
  ///
  /// If something is already running this waits for it rather than refusing.
  /// Starting the hotspot takes Windows a couple of seconds, and a tap that
  /// lands in that window should still be honoured instead of being answered
  /// with "busy" - which is what made the controls feel dead.
  Future<HelperResult> _run(String action, [Map<String, dynamic> payload = const {}]) async {
    var waited = Duration.zero;
    while (_busy && mounted && waited < const Duration(seconds: 30)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      waited += const Duration(milliseconds: 50);
    }

    setState(() => _inflight++);
    try {
      final result = await _service.call(action, payload);
      _report(result);
      return result;
    } finally {
      if (mounted) {
        setState(() => _inflight--);
      } else {
        _inflight--;
      }
    }
  }

  Future<void> _refresh() async {
    if (_slowBusy || !_started || !mounted) return;
    _slowBusy = true;
    try {
      final status = await _service.status(hint: _sourceHint);
      if (!mounted) return;
      setState(() {
        _status = status;
        if (status.sourceHint != null) _sourceHint = status.sourceHint;
      });
      _adoptLiveConfig(status);
    } catch (_) {
      // Polling failures are shown through the last action result instead of
      // spamming the log every few seconds.
    } finally {
      _slowBusy = false;
    }
  }

  /// The fast poll. Runs the cheap helper action on a short interval so the
  /// on/off state and the device list follow the hotspot closely, including when
  /// it is switched from the Windows Settings app rather than from here.
  ///
  /// This deliberately keeps running while one of the user's own actions is in
  /// flight, and while the slow sweep is running, because each of them is
  /// answered by a different helper process. Letting the slow sweep block this
  /// one is what used to leave the device list and the on/off badge minutes
  /// behind reality.
  Future<void> _refreshQuick() async {
    if (_quickBusy || !_started || !mounted) return;
    _quickBusy = true;
    try {
      final quick = await _service.quick(hint: _sourceHint);
      if (!mounted) return;
      setState(() {
        _status = _status.withQuick(quick);
        if (quick.source != null) _sourceHint = quick.source;
      });
      // A read that could not find the hotspot has nothing to mirror into the
      // fields, and would only overwrite what is already correct.
      if (!quick.known) return;
      _adoptLiveConfig(_status);
    } catch (_) {
      // Same as _refresh: a missed poll is not worth a log line.
    } finally {
      _quickBusy = false;
    }
  }

  void _startPolling() {
    _timer?.cancel();
    // A warm helper answers the cheap read in a few milliseconds, so this is the
    // real refresh rate rather than a hopeful one. It is the difference between
    // a device appearing the moment it joins and it appearing on the next sweep.
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _refreshQuick());
    _slowTimer?.cancel();
    // The full sweep covers the things that only change when the user changes
    // them - the blocked list, the firewall rules, the keep-alive flag - so it
    // does not need to run nearly as often as the cheap read.
    _slowTimer = Timer.periodic(const Duration(seconds: 12), (_) => _refresh());
  }

  /// Brings the screen up to date after an action. The cheap read is enough for
  /// everything the user can see changing, so the slow sweep is left to run on
  /// its own schedule instead of stalling the button.
  Future<void> _settle() async {
    await _refreshQuick();
  }

  /// Mirrors the settings Windows actually has into the text fields, so the app
  /// follows the Windows Settings app and any change made elsewhere instead of
  /// insisting on its own remembered copy.
  ///
  /// A field the user has edited but not yet applied is never touched, and no
  /// dirty flag is ever cleared here. Polling used to overwrite the field and
  /// mark it clean a fraction of a second after a keystroke, which is why a new
  /// password or band could be typed in and then simply vanish - and why the
  /// Apply button went back to looking disabled on its own.
  void _adoptLiveConfig(HotspotStatus status) {
    final liveSsid = status.ssid;
    final livePass = status.passphrase;
    final liveBand = status.band;
    if (liveSsid == null && livePass == null && liveBand == null) return;

    // Nothing to adopt into a field the user is still working on, or has already
    // changed and not applied.
    final takeSsid = !_ssidDirty && !_ssidFocus.hasFocus && liveSsid != null && _ssid.text != liveSsid;
    final takePass = !_passwordDirty &&
        !_passwordFocus.hasFocus &&
        livePass != null &&
        livePass.isNotEmpty &&
        _password.text != livePass;
    final takeBand = !_bandDirty && liveBand != null && liveBand.isNotEmpty && _band != liveBand;
    if (!takeSsid && !takePass && !takeBand) {
      if (!_adoptedLiveConfig && liveSsid != null && liveBand != null) {
        setState(() => _adoptedLiveConfig = true);
      }
      return;
    }

    setState(() {
      if (takeSsid) _ssid.text = liveSsid;
      if (takePass) _password.text = livePass;
      if (takeBand) _band = liveBand;
      _adoptedLiveConfig = true;
    });
  }

  // ----------------------------------------------------------------- actions

  /// Switches between normal and no-internet.
  ///
  /// The control moves the moment it is tapped, and a tap that lands while an
  /// earlier change is still running is remembered rather than dropped, so the
  /// last one wins. Rebuilding the firewall rules is the slow part and it no
  /// longer holds the toggle hostage.
  Future<void> _selectMode(HotspotMode mode) async {
    if (mode == _mode) return;
    final previous = _mode;
    setState(() => _mode = mode);
    _save();

    if (_modeBusy) {
      _pendingMode = mode;
      return;
    }

    _modeBusy = true;
    try {
      var committed = previous;
      var target = mode;
      while (true) {
        final result = await _run('setmode', <String, dynamic>{'mode': target.wire});
        await _settle();
        if (!result.ok) {
          // Put the last mode that actually applied back, so the UI never
          // claims something that is not true.
          if (mounted) setState(() => _mode = committed);
          _pendingMode = null;
          return;
        }
        committed = target;
        final next = _pendingMode;
        _pendingMode = null;
        if (next == null || next == target) break;
        target = next;
      }
      _say('Mode set to "${target.title}".', LogKind.info);
    } finally {
      _modeBusy = false;
    }
  }

  Future<void> _toggleHotspot() async {
    if (_status.on) {
      await _run('stop', <String, dynamic>{'hint': _sourceHint ?? ''});
      await _settle();
      return;
    }

    _save();
    final result = await _run('start', <String, dynamic>{
      'mode': _mode.wire,
      // Only a field the user actually edited is sent. Everything else is left
      // out so the helper keeps what Windows already holds, which means turning
      // the hotspot on never quietly rewrites a name, password or band that
      // someone set in the Windows Settings app.
      'ssid': _ssidDirty ? _ssid.text.trim() : '',
      'passphrase': _passwordDirty ? _password.text : '',
      'band': _bandDirty ? _band : '',
      'source': '',
    });
    await _settle();
    if (result.ok && _keepAlive) {
      await _run('timeout', <String, dynamic>{'enabled': false});
    }
  }

  /// Pushes the edited settings to Windows.
  ///
  /// This runs whether or not the hotspot is on. Windows stores an access point
  /// configuration happily while tethering is off and uses it the next time it
  /// starts, so holding the change back until a start - which is what the old
  /// "Saved" message did - meant a password typed in before switching the
  /// hotspot on was quietly thrown away.
  Future<void> _applySettings() async {
    _save();

    if (!_ssidDirty && !_passwordDirty && !_bandDirty) {
      _say('Nothing was edited, so Windows keeps the settings it already has.', LogKind.info);
      return;
    }

    final payload = <String, dynamic>{'hint': _sourceHint ?? ''};
    if (_ssidDirty) payload['ssid'] = _ssid.text.trim();
    if (_passwordDirty) payload['passphrase'] = _password.text;
    if (_bandDirty) payload['band'] = _band;

    final result = await _run('configure', payload);
    if (result.ok && mounted) {
      // Cleared before settling, so the very next fast poll is allowed to mirror
      // what Windows now holds back into the fields. Clearing afterwards left the
      // fields sitting on the value that was just replaced.
      setState(() {
        _ssidDirty = false;
        _passwordDirty = false;
        _bandDirty = false;
      });
    }
    await _settle();
  }

  // -------------------------------------------------------------- block list

  /// Refuses one device. The helper does the work; the list it returns is the
  /// truth, so the UI follows it rather than assuming the change took.
  Future<void> _block(String mac) async {
    final result = await _run('block', <String, dynamic>{'mac': mac});
    if (!result.ok) return;
    final blocked = (result.data['blocked'] as List?)
            ?.map((e) => normalizeMac(e.toString()))
            .toList(growable: false) ??
        const <String>[];
    setState(() => _status = _status.copyWithBlocked(blocked));
  }

  Future<void> _unblock(String mac) async {
    final result = await _run('unblock', <String, dynamic>{'mac': mac});
    if (!result.ok) return;
    final blocked = (result.data['blocked'] as List?)
            ?.map((e) => normalizeMac(e.toString()))
            .toList(growable: false) ??
        const <String>[];
    setState(() => _status = _status.copyWithBlocked(blocked));
  }

  Future<void> _clearBlocked() async {
    final result = await _run('clearblocks');
    if (!result.ok) return;
    setState(() => _status = _status.copyWithBlocked(const <String>[]));
  }

  Future<void> _randomPassword() async {
    final rand = DateTime.now().microsecondsSinceEpoch;
    const alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final buffer = StringBuffer();
    var seed = rand;
    for (var i = 0; i < 12; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      buffer.write(alphabet[seed % alphabet.length]);
    }
    setState(() {
      _password.text = buffer.toString();
      _passwordDirty = true;
    });
  }

  /// Drops the pending edits and puts the live Windows values back in the
  /// fields, for when a change made in the Windows Settings app should win.
  void _discardEdits() {
    _ssidDirty = false;
    _passwordDirty = false;
    _bandDirty = false;
    final status = _status;
    setState(() {
      if (status.ssid != null) _ssid.text = status.ssid!;
      if (status.passphrase != null && status.passphrase!.isNotEmpty) {
        _password.text = status.passphrase!;
      }
      if (status.band != null && status.band!.isNotEmpty) _band = status.band!;
    });
    _say('Reverted to the settings Windows currently has.', LogKind.info);
  }

  Future<void> _setKeepAlive(bool value) async {
    setState(() => _keepAlive = value);
    _save();
    final result = await _run('timeout', <String, dynamic>{'enabled': !value});
    if (result.ok) {
      setState(() => _keepAlive = !(result.data['enabled'] == true));
      _save();
    }
    await _refresh();
  }

  Future<void> _cleanup() async {
    await _run('cleanup', <String, dynamic>{'hint': _sourceHint ?? ''});
    await _settle();
  }

  /// Copies the whole activity log, plus a snapshot of the current state, to the
  /// clipboard. The snapshot is included so a pasted report is enough to tell
  /// what Windows was doing at the time, without having to reproduce anything.
  Future<void> _copyLogs() async {
    final status = _status;
    final buffer = StringBuffer()
      ..writeln('=== LanSpot report ===')
      ..writeln('copied at: ${DateTime.now().toIso8601String()}')
      ..writeln('mode: ${_mode.wire}')
      ..writeln('ssid setting: ${_ssid.text}')
      ..writeln('band setting: ${bandLabel(_band)}')
      ..writeln()
      ..writeln('--- current status ---')
      ..writeln('elevated: ${status.elevated}')
      ..writeln(
        'hotspot: ${status.on ? 'ON' : 'off'} (${status.state}), '
        'ssid=${status.ssid}, clients=${status.clients}, source=${status.source}',
      )
      ..writeln(
        'band: ${status.band}, nic: ${status.nic}, subnet: ${status.subnet}',
      )
      ..writeln(
        'wifi: ${status.wifiStatus} (${status.wifiAlias}), '
        'internet: ${status.internetAvailable} ${status.internetProfile ?? ''}',
      )
      ..writeln(
        'firewall: ${status.firewallApplied ? status.firewallRules.join(' | ') : 'no rules'}',
      )
      ..writeln(
        'devices: ${status.clientList.isEmpty ? '(none)' : status.clientList.map((c) => '${c.mac}${c.ip == null ? '' : ' @ ${c.ip}'}${c.blocked ? ' [blocked]' : ''}').join(' | ')}',
      )
      ..writeln(
        'blocked: ${status.blocked.isEmpty ? '(none)' : status.blocked.map(macLabel).join(' | ')}',
      )
      ..writeln(
        'noConnectionsTimeout: ${status.noConnectionsTimeout}, '
        'icsRunning: ${status.icsRunning}',
      );

    if (status.notes.isNotEmpty) {
      buffer.writeln('notes: ${status.notes.join(' | ')}');
    }
    if (_lastError != null) {
      buffer.writeln('last error: $_lastError');
    }

    buffer
      ..writeln()
      ..writeln('--- activity log (${_log.length} entries, oldest first) ---');

    for (final entry in _log.reversed) {
      buffer.writeln(
        '${entry.at.toIso8601String()} [${entry.kind.name}] ${entry.text}',
      );
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Copied ${_log.length} log entries and the current status. '
          'Paste it anywhere.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _showDiagnostics() async {
    final result = await _run('diagnose');
    if (!result.ok || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Diagnostics'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(result.data),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final t = TokensScope.of(context);

    if (_elevating) return _ElevatingScreen(tokens: t);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The log rail only earns its place when there is real room for it.
            final rail = constraints.maxWidth >= 1040;
            final gutter = constraints.maxWidth >= 1400 ? 32.0 : 20.0;

            final main = SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(gutter, 16, rail ? 20 : gutter, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _topBar(t),
                    if (!_status.elevated) ...<Widget>[
                      const SizedBox(height: 14),
                      _ElevationNotice(tokens: t),
                    ],
                    const SizedBox(height: 16),
                    _hero(t),
                    const SizedBox(height: 12),
                    _modePanel(t),
                    const SizedBox(height: 12),
                    _settingsPanel(t),
                    const SizedBox(height: 12),
                    _extrasPanel(t),
                  ],
                ),
              ),
            );

            if (!rail) {
              return Column(
                children: <Widget>[
                  Expanded(child: main),
                  const Divider(height: 1),
                  SizedBox(height: 260, child: _rail(t)),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: main),
                VerticalDivider(width: 1, color: t.hairline),
                SizedBox(width: 320, child: _rail(t)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _topBar(Tokens t) {
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            'LanSpot',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const Spacer(),
        _RailAction(
          icon: Icons.refresh_rounded,
          tooltip: 'Refresh now',
          onTap: _refresh,
          enabled: !_busy,
        ),
        _RailAction(
          icon: Icons.insights_outlined,
          tooltip: 'Diagnostics',
          onTap: _showDiagnostics,
          enabled: !_busy,
        ),
        const SizedBox(width: 2),
        _ThemeToggle(dark: widget.darkMode, onTap: widget.onToggleTheme, tokens: t),
      ],
    );
  }

  /// The one thing worth looking at. Everything else on screen is secondary to
  /// "is the hotspot on, and what is it called".
  ///
  /// While an action is in flight the frame runs a travelling light around the
  /// edge. That is the whole feedback loop for work that takes a few seconds of
  /// Windows time, so it matters that the border moves rather than just
  /// changing colour.
  Widget _hero(Tokens t) {
    final status = _status;
    final on = status.on;
    final accent = t.modeColor(_mode, on: on);
    final wash = t.modeWash(_mode, on: on);

    return _LiveFrame(
      busy: _busy,
      color: accent,
      radius: 16,
      idleBorder: on ? accent.withValues(alpha: 0.35) : t.hairline,
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
        decoration: BoxDecoration(
          color: on ? wash : t.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          // The status dot pulses only while the hotspot is live,
                          // which is the only other motion in the app.
                          _StatusDot(color: accent, live: on),
                          const SizedBox(width: 10),
                          Text(
                            on ? 'On' : 'Off',
                            key: const ValueKey<String>('hero-state'),
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(color: accent),
                          ),
                          if (_busy) ...<Widget>[
                            const SizedBox(width: 10),
                            _WorkingChip(tokens: t),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        status.ssid ?? 'No hotspot name reported',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: on ? t.ink : t.inkMuted,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _toggleHotspot,
                  style: FilledButton.styleFrom(
                    backgroundColor: on ? t.ink : accent,
                    foregroundColor: on ? t.canvas : t.onAccent,
                    disabledBackgroundColor: t.hairline,
                    disabledForegroundColor: t.inkMuted,
                  ),
                  icon: Icon(on ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 20),
                  label: Text(on ? 'Turn off' : 'Turn on'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Divider(color: on ? accent.withValues(alpha: 0.18) : t.hairline, height: 1),
            const SizedBox(height: 14),
            Wrap(
              spacing: 16,
              runSpacing: 10,
              children: <Widget>[
                _Meta(
                  label: 'Devices',
                  value: status.blocked.isEmpty
                      ? '${status.clients}'
                      : '${status.clients} (${status.blocked.length} blocked)',
                  tokens: t,
                ),
                _Meta(
                  label: 'Sharing',
                  value: on ? (status.source ?? 'unknown') : 'not running',
                  tokens: t,
                ),
                _Meta(
                  label: 'Band',
                  value: status.band == null ? '-' : bandLabel(status.band!),
                  tokens: t,
                ),
                _Meta(
                  label: 'Security',
                  value: status.auth ?? '-',
                  tokens: t,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modePanel(Tokens t) {
    return _Panel(
      tokens: t,
      title: 'Behaviour',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SegmentedToggle<HotspotMode>(
            tokens: t,
            value: _mode,
            // Always tappable. The firewall rebuild behind a mode change is the
            // slow part; disabling the control while it ran is exactly what made
            // the tabs feel unresponsive.
            onChanged: _selectMode,
            items: <SegmentedItem<HotspotMode>>[
              SegmentedItem<HotspotMode>(
                value: HotspotMode.normal,
                label: 'Normal',
                icon: Icons.public_rounded,
              ),
              SegmentedItem<HotspotMode>(
                value: HotspotMode.noInternet,
                label: 'No internet',
                icon: Icons.signal_wifi_statusbar_connected_no_internet_4_rounded,
              ),
            ],
          ),
          // Under the control rather than beside its title, so it wraps instead
          // of fighting the toggle for a single line.
          const SizedBox(height: 10),
          Text(
            _mode.blurb,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _settingsPanel(Tokens t) {
    final edited = _ssidDirty || _passwordDirty || _bandDirty;
    return _Panel(
      tokens: t,
      title: 'Network',
      trailing: _adoptedLiveConfig
          ? Text(
              edited ? 'Unsaved changes' : 'Synced with Windows',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: edited ? t.starved : t.inkMuted,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, c) {
              final stack = c.maxWidth < 460;
              final name = TextField(
                controller: _ssid,
                focusNode: _ssidFocus,
                onChanged: (_) => _ssidDirty = true,
                decoration: const InputDecoration(labelText: 'Network name'),
              );
              final password = TextField(
                controller: _password,
                focusNode: _passwordFocus,
                obscureText: !_showPassword,
                onChanged: (_) => _passwordDirty = true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _FieldAction(
                        icon: Icons.casino_outlined,
                        tooltip: 'Generate a password',
                        onTap: _randomPassword,
                      ),
                      _FieldAction(
                        icon: _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        tooltip: _showPassword ? 'Hide password' : 'Show password',
                        onTap: () => setState(() => _showPassword = !_showPassword),
                      ),
                    ],
                  ),
                ),
              );
              if (stack) {
                return Column(
                  children: <Widget>[name, const SizedBox(height: 10), password],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: name),
                  const SizedBox(width: 10),
                  Expanded(child: password),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Text('Band', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          SegmentedToggle<String>(
            tokens: t,
            value: _band,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                      _band = value;
                      _bandDirty = true;
                    }),
            items: kBands
                .map((band) => SegmentedItem<String>(
                      value: band,
                      label: bandLabel(band),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              FilledButton(
                onPressed: _busy || !edited ? null : _applySettings,
                style: FilledButton.styleFrom(
                  backgroundColor: t.ink,
                  foregroundColor: t.canvas,
                  disabledBackgroundColor: Colors.transparent,
                  disabledForegroundColor: t.inkMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  side: edited ? null : BorderSide(color: t.hairline),
                ),
                child: const Text('Apply'),
              ),
              if (edited) ...<Widget>[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: _busy ? null : _discardEdits,
                  child: const Text('Discard'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _extrasPanel(Tokens t) {
    return _Panel(
      tokens: t,
      title: 'Behaviour and safety',
      child: Column(
        children: <Widget>[
          _SwitchRow(
            tokens: t,
            title: 'Keep it on when nobody connects',
            subtitle: 'Stops Windows switching the hotspot off on its own.',
            value: _keepAlive,
            onChanged: _busy ? null : _setKeepAlive,
          ),
          _Divider(tokens: t),
          _SwitchRow(
            tokens: t,
            title: 'Start it when this app opens',
            value: _autoStart,
            onChanged: (value) async {
              setState(() => _autoStart = value);
              _save();
            },
          ),
          _Divider(tokens: t),
          _SwitchRow(
            tokens: t,
            title: 'My Wi-Fi',
            subtitle: _status.wifiAlias.isEmpty
                ? 'No adapter found'
                : '${_status.wifiAlias} is ${_status.wifiStatus.toLowerCase()}',
            value: _status.wifiUp,
            onChanged: _busy
                ? null
                : (_) => _run('wifi', <String, dynamic>{'on': !_status.wifiUp})
                    .then((_) => _refresh()),
            trailing: Text(
              _status.wifiUp ? 'On' : 'Off',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _status.wifiUp ? t.accent : t.inkMuted,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _cleanup,
              style: TextButton.styleFrom(
                foregroundColor: t.inkMuted,
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(Icons.cleaning_services_outlined, size: 17),
              label: const Text('Reset: remove firewall rules and release the hotspot'),
            ),
          ),
        ],
      ),
    );
  }

  /// The right rail. Devices and Activity are both live lists that the user
  /// refers to constantly, so they share the space and swap in place rather than
  /// each pushing the other further down a scrolling page.
  Widget _rail(Tokens t) {
    return Container(
      color: t.canvas,
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _RailTabs(
            tokens: t,
            index: _railTab,
            onChanged: (value) => setState(() => _railTab = value),
            devices: _status.blocked.length,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _railTab == 0 ? _devicesView(t) : _activityView(t),
          ),
        ],
      ),
    );
  }

  Widget _devicesView(Tokens t) {
    final status = _status;
    final connected = status.clientList;

    if (!status.on && status.blocked.isEmpty) {
      return _EmptyState(
        tokens: t,
        icon: Icons.devices_other_outlined,
        message: 'Devices appear here once the hotspot is on.',
      );
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        if (status.blocked.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                Text('BLOCKED', style: Theme.of(context).textTheme.labelSmall),
                const Spacer(),
                _RailAction(
                  icon: Icons.restart_alt_rounded,
                  tooltip: 'Allow every blocked device back on',
                  onTap: _clearBlocked,
                  enabled: !_busy,
                ),
              ],
            ),
          ),
        for (final mac in status.blocked)
          _DeviceRow(
            tokens: t,
            mac: mac,
            ip: _ipFor(mac),
            connected: connected.any((c) => c.mac == mac),
            blocked: true,
            onToggle: _busy ? null : () => _unblock(mac),
          ),
        if (status.blocked.isNotEmpty && connected.isNotEmpty)
          const SizedBox(height: 14),
        if (connected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('CONNECTED', style: Theme.of(context).textTheme.labelSmall),
          ),
        for (final client in connected)
          if (!client.blocked)
            _DeviceRow(
              tokens: t,
              mac: client.mac,
              ip: client.ip,
              connected: true,
              blocked: false,
              onToggle: _busy ? null : () => _block(client.mac),
            ),
        if (connected.isEmpty && status.blocked.isEmpty)
          _EmptyState(
            tokens: t,
            icon: Icons.devices_other_outlined,
            message: 'Nobody has joined yet.',
          ),
      ],
    );
  }

  String? _ipFor(String mac) {
    for (final client in _status.clientList) {
      if (client.mac == mac) return client.ip;
    }
    return null;
  }

  Widget _activityView(Tokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('ACTIVITY', style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            _RailAction(
              icon: Icons.copy_all_outlined,
              tooltip: 'Copy the log and current status',
              onTap: _copyLogs,
            ),
            _RailAction(
              icon: Icons.close_rounded,
              tooltip: 'Clear the log',
              onTap: () => setState(_log.clear),
              enabled: _log.isNotEmpty,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _log.isEmpty
              ? _EmptyState(tokens: t, icon: Icons.bolt_outlined, message: 'Nothing yet.')
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: _log.length,
                  itemBuilder: (context, index) {
                    final entry = _log[index];
                    return _LogLine(entry: entry, tokens: t, index: index);
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

/// Draws a rounded border with a highlight travelling around it.
///
/// Starting the hotspot means waiting on Windows, and a spinner alone leaves the
/// user unsure whether anything is happening. A moving edge reads as "working on
/// it" without adding a second panel of chrome to the layout.
class _LiveFrame extends StatefulWidget {
  const _LiveFrame({
    required this.busy,
    required this.color,
    required this.radius,
    required this.child,
    required this.idleBorder,
  });

  final bool busy;
  final Color color;
  final double radius;
  final Widget child;
  final Color idleBorder;

  @override
  State<_LiveFrame> createState() => _LiveFrameState();
}

class _LiveFrameState extends State<_LiveFrame> with SingleTickerProviderStateMixin {
  // Built in initState, not in a field initialiser, so the controller is never
  // constructed while the element is already being torn down.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.busy) _controller.repeat();
  }

  @override
  void didUpdateWidget(_LiveFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy == oldWidget.busy) return;
    if (widget.busy) {
      _controller.repeat();
    } else {
      // Snap back to the end so the light does not stop mid-edge and look stuck.
      _controller.animateTo(1.0).whenComplete(() {
        if (mounted) _controller.value = 0.0;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.busy) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(color: widget.idleBorder),
        ),
        child: widget.child,
      );
    }

    return CustomPaint(
      painter: _SweepPainter(
        angle: _controller.value * 6.2831853,
        color: widget.color,
        radius: widget.radius,
        track: widget.idleBorder,
      ),
      child: widget.child,
    );
  }
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter({
    required this.angle,
    required this.color,
    required this.radius,
    required this.track,
  });

  final double angle;
  final Color color;
  final double radius;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outer = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // A quiet track so the moving edge never disappears against the surface.
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = track,
    );

    // The dashes travel *along* the border rather than the border rotating.
    // Sliding the pattern along the measured path is what makes the line itself
    // appear to flow, rather than the whole rectangle spinning on the spot.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..color = color;

    final metric = (Path()..addRRect(outer)).computeMetrics().first;
    final total = metric.length;
    if (total <= 0) return;

    // A short dash with a long gap, so at any moment only a few segments are lit
    // and the eye follows a moving head around the edge.
    const dashCount = 11;
    final dash = total * (0.9 / dashCount);
    final step = total / dashCount;
    final travel = angle / (2 * math.pi) * total;

    for (var i = 0; i < dashCount; i++) {
      var start = (i * step - travel) % total;
      if (start < 0) start += total;
      final end = math.min(start + dash, total);
      canvas.drawPath(metric.extractPath(start, end), stroke);
      // A dash that runs past the start of the path wraps to the far end.
      if (start + dash > total) {
        canvas.drawPath(metric.extractPath(0, start + dash - total), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      old.angle != angle || old.color != color || old.radius != radius || old.track != track;
}

/// The "working" tag next to the state. Deliberately plain - the moving frame
/// already says that something is happening.
class _WorkingChip extends StatelessWidget {
  const _WorkingChip({required this.tokens});

  final Tokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: tokens.hairline),
      ),
      child: Text(
        'working',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: tokens.inkMuted,
        ),
      ),
    );
  }
}

/// The two live lists share the rail, so the switch is a small underline rather
/// than a filled control that would compete with the mode selector.
class _RailTabs extends StatelessWidget {
  const _RailTabs({
    required this.tokens,
    required this.index,
    required this.onChanged,
    required this.devices,
  });

  final Tokens tokens;
  final int index;
  final ValueChanged<int> onChanged;
  final int devices;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _RailTab(
          tokens: tokens,
          label: 'Devices',
          count: devices,
          selected: index == 0,
          onTap: () => onChanged(0),
        ),
        const SizedBox(width: 18),
        _RailTab(
          tokens: tokens,
          label: 'Activity',
          count: 0,
          selected: index == 1,
          onTap: () => onChanged(1),
        ),
      ],
    );
  }
}

class _RailTab extends StatelessWidget {
  const _RailTab({
    required this.tokens,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final Tokens tokens;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: selected ? tokens.ink : tokens.inkMuted,
                  ),
                ),
                if (count > 0) ...<Widget>[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: tokens.dangerWash,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: tokens.danger,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              width: selected ? 22 : 0,
              decoration: BoxDecoration(
                color: tokens.ink,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One device. The whole row is the control, so there is nothing small to miss.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.tokens,
    required this.mac,
    required this.ip,
    required this.connected,
    required this.blocked,
    required this.onToggle,
  });

  final Tokens tokens;
  final String mac;
  final String? ip;
  final bool connected;
  final bool blocked;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final foreground = blocked ? tokens.inkMuted : tokens.ink;

    return Tooltip(
      message: blocked ? 'Allow this device back on' : 'Refuse this device',
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
          child: Row(
            children: <Widget>[
              Icon(
                blocked ? Icons.block_rounded : Icons.devices_rounded,
                size: 17,
                color: blocked ? tokens.danger : tokens.inkMuted,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      macLabel(mac),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      blocked
                          ? (ip == null ? 'refused' : 'refused \u00b7 $ip')
                          : (ip ?? 'connected'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: tokens.inkMuted),
                    ),
                  ],
                ),
              ),
              if (onToggle != null)
                Icon(
                  blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                  size: 16,
                  color: tokens.hairlineStrong,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled group. Flat surface, one hairline, no shadow.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.tokens,
    required this.title,
    required this.child,
    this.trailing,
  });

  final Tokens tokens;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.tokens});

  final Tokens tokens;

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: tokens.hairline, thickness: 1);
}

/// Label-over-value metadata row inside the hero.
class _Meta extends StatelessWidget {
  const _Meta({
    required this.label,
    required this.value,
    required this.tokens,
  });

  final String label;
  final String value;
  final Tokens tokens;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 3),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: tokens.ink,
            ),
          ),
        ),
      ],
    );
  }
}

/// A dot that breathes while the hotspot is live, so a glance is enough.
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, required this.live});

  final Color color;
  final bool live;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  // Built in initState rather than in a field initialiser: a lazy initialiser
  // would construct the controller on first use, which can happen while the
  // element is already being disposed, and touching vsync then throws.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.live) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.live == oldWidget.live) return;
    if (widget.live) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.live) {
      return Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: widget.color, width: 2),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final glow = 0.18 + (_controller.value * 0.34);
        return Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: <BoxShadow>[
              BoxShadow(color: widget.color.withValues(alpha: glow), blurRadius: 10),
            ],
          ),
        );
      },
    );
  }
}

/// Segmented control. The active segment fills with a solid colour; inactive
/// segments stay on the surface so the control reads as one object.
class SegmentedItem<T> {
  const SegmentedItem({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

class SegmentedToggle<T> extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.tokens,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final Tokens tokens;
  final T value;
  final List<SegmentedItem<T>> items;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: tokens.isDark ? const Color(0xFF191D22) : const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: tokens.hairline),
      ),
      child: Row(
        children: items.map((item) {
          final selected = item.value == value;
          return Expanded(
            child: _Segment(
              tokens: tokens,
              item: item,
              selected: selected,
              enabled: onChanged != null,
              onTap: onChanged == null ? null : () => onChanged!(item.value),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.tokens,
    required this.item,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Tokens tokens;
  final SegmentedItem<dynamic> item;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? tokens.accent : tokens.inkMuted;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? tokens.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (item.icon != null) ...<Widget>[
                Icon(item.icon, size: 16, color: foreground),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? tokens.ink : tokens.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.tokens,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.trailing,
  });

  final Tokens tokens;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.bodyMedium),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            trailing!,
            const SizedBox(width: 10),
          ],
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _FieldAction extends StatelessWidget {
  const _FieldAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 18, color: TokensScope.of(context).inkMuted),
        ),
      ),
    );
  }
}

class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = TokensScope.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(
            icon,
            size: 17,
            color: enabled ? t.inkMuted : t.hairlineStrong,
          ),
        ),
      ),
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle({
    required this.dark,
    required this.onTap,
    required this.tokens,
  });

  final bool dark;
  final VoidCallback onTap;
  final Tokens tokens;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: dark ? 'Switch to light' : 'Switch to dark',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) =>
                RotationTransition(turns: animation, child: child),
            child: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              key: ValueKey<bool>(dark),
              size: 19,
              color: tokens.inkMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _ElevationNotice extends StatelessWidget {
  const _ElevationNotice({required this.tokens});

  final Tokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.starvedWash,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.starved.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.shield_outlined, size: 19, color: tokens.starved),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Not running as administrator. Firewall rules and starting the '
              'hotspot will not work.',
              style: TextStyle(fontSize: 12.5, color: tokens.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.entry,
    required this.tokens,
    required this.index,
  });

  final LogEntry entry;
  final Tokens tokens;
  final int index;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.kind) {
      LogKind.good => tokens.accent,
      LogKind.warn => tokens.starved,
      LogKind.bad => tokens.danger,
      LogKind.info => tokens.inkMuted,
    };

    // Fade the oldest entries so the newest one always dominates the rail.
    final recency = (1 - (index / 60)).clamp(0.35, 1.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.text,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: Color.lerp(tokens.inkMuted, tokens.ink, recency),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  entry.at.toIso8601String().substring(11, 19),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    color: Color.lerp(tokens.hairlineStrong, color, recency),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.tokens,
    required this.icon,
    required this.message,
  });

  final Tokens tokens;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: tokens.hairlineStrong),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: tokens.inkMuted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _ElevatingScreen extends StatelessWidget {
  const _ElevatingScreen({required this.tokens});

  final Tokens tokens;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: tokens.accent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Waiting for permission',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Choose Yes in the administrator prompt.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

