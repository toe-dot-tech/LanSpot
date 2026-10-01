import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';

/// Talks to the bundled PowerShell helper.
///
/// The helper runs as a long-lived process rather than one process per call.
/// Starting PowerShell costs about 400ms before it executes a single line, and
/// the NetTCPIP/NetSecurity module loads cost seconds more; the app polls
/// several times a second, so a fresh process per poll is what used to make the
/// UI feel frozen. Two servers are kept instead:
///
///  * a *fast* one that only ever runs [quick], so a poll can never be stuck
///    behind a slow action like starting the hotspot, and
///  * a *main* one that runs everything else, where a call may legitimately take
///    a couple of seconds while Windows works.
///
/// The helper extracts from the app's assets into the temp folder on first use,
/// because PowerShell can only execute a real file.
class HotspotService {
  HotspotService({Duration? timeout}) : _timeout = timeout ?? const Duration(seconds: 120);

  static const String _powershell =
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
  static const String _assetPath = 'assets/hotspot_helper.ps1';

  final Duration _timeout;

  File? _script;
  _HelperServer? _fast;
  _HelperServer? _main;
  bool _disposed = false;

  Future<File> _helperScript() async {
    final existing = _script;
    if (existing != null && await existing.exists()) return existing;

    final source = await rootBundle.loadString(_assetPath);
    final dir = await Directory.systemTemp.createTemp('lanspot_');
    final file = File('${dir.path}${Platform.pathSeparator}hotspot_helper.ps1');
    await file.writeAsString(source, encoding: utf8, flush: true);
    _script = file;
    return file;
  }

  Future<_HelperServer> _serverFor(bool fast) async {
    final current = fast ? _fast : _main;
    if (current != null && current.alive) return current;

    final script = await _helperScript();
    final server = _HelperServer(script, _powershell, _timeout, label: fast ? 'quick' : 'main');
    if (fast) {
      _fast = server;
    } else {
      _main = server;
    }
    await server.start();
    return server;
  }

  /// Invokes [action] and returns the parsed reply.
  Future<HelperResult> call(String action, [Map<String, dynamic> payload = const {}]) async {
    if (_disposed) return HelperResult.fail('The helper was shut down.');
    try {
      final server = await _serverFor(action == 'quick');
      final raw = await server.request(action, payload);
      return HelperResult.parse(raw);
    } on _HelperUnavailable catch (e) {
      return HelperResult.fail(e.message);
    } catch (e) {
      return HelperResult.fail('Could not reach the helper: $e');
    }
  }

  Future<HotspotStatus> status({String? hint}) async {
    final result = await call('status', <String, dynamic>{'hint': hint ?? ''});
    if (!result.ok) throw HelperException(result.error!, result.line);
    return HotspotStatus.fromJson(result.data);
  }

  /// Reads only what changes quickly: the tethering state and who is connected.
  /// Warm, this answers in single-digit milliseconds because the helper keeps the
  /// tethering manager and the profile it lives on in memory between calls.
  Future<QuickState> quick({String? hint}) async {
    final result = await call('quick', <String, dynamic>{'hint': hint ?? ''});
    if (!result.ok) throw HelperException(result.error!, result.line);
    return QuickState.fromJson(result.data);
  }

  /// Shuts both helper processes down. Called when the app closes so no
  /// stray PowerShell windows are left behind.
  void dispose() {
    _disposed = true;
    _fast?.dispose();
    _main?.dispose();
    _fast = null;
    _main = null;
  }
}

/// Thrown when the helper process could not be started or has gone away.
class _HelperUnavailable implements Exception {
  _HelperUnavailable(this.message);
  final String message;
}

/// One long-lived `powershell.exe -Action server`.
///
/// The app opens a loopback port and the helper connects back to it. Requests
/// are written as one JSON object per line and the replies come back the same
/// way. They are answered in order, so a queue of waiters is kept and the oldest
/// outstanding request is completed by each line that arrives. This is what lets
/// the caller `await` a call without any framing of its own.
///
/// A socket is used rather than the child's stdin because Windows PowerShell
/// never sees a line written to its redirected stdin - it only reads the console
/// - so a persistent child fed that way waits forever for requests that have in
/// fact already been sent.
class _HelperServer {
  _HelperServer(this.script, this.powershell, this.timeout, {required this.label});

  final File script;
  final String powershell;
  final Duration timeout;
  final String label;

  Process? _process;
  ServerSocket? _listener;
  Socket? _socket;
  StreamSubscription<String>? _lines;
  final List<Completer<String>> _waiting = <Completer<String>>[];
  Completer<void>? _ready;
  bool _alive = false;

  bool get alive => _alive && _process != null && _socket != null;

  Future<void> start() async {
    if (alive) return;
    _ready = Completer<void>();
    _alive = false;

    final ServerSocket listener;
    try {
      // Port 0 lets the OS pick a free port, which avoids colliding with anything
      // else and means two copies of the app cannot fight over one address.
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    } catch (e) {
      _ready = null;
      throw _HelperUnavailable('Could not open a local port for the helper: $e');
    }
    _listener = listener;

    final Process process;
    try {
      process = await Process.start(
        powershell,
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-Action',
          'server',
          '-Port',
          '${listener.port}',
        ],
        workingDirectory: script.parent.path,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      await listener.close();
      _listener = null;
      _ready = null;
      throw _HelperUnavailable('Could not start the helper: ${e.message}');
    }

    _process = process;
    _alive = true;
    process.stderr.drain<void>();
    unawaited(process.exitCode.then((_) => _onGone('The helper stopped.')));

    try {
      _socket = await listener.first.timeout(const Duration(seconds: 60));
      _listener = null; // `first` cancels the subscription, closing the listener.
      _lines = _socket!
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: (Object _) => _onGone('The helper connection failed.'),
            cancelOnError: false,
          );
      await _ready!.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      _onGone('The helper did not start in time.');
      throw _HelperUnavailable('The helper did not start in time.');
    }

    if (!_alive) throw _HelperUnavailable('The helper stopped while starting up.');
  }

  void _onLine(String line) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      // The first line is the helper's greeting, not an answer to anything.
      ready.complete();
      return;
    }
    if (_waiting.isEmpty) return;
    _waiting.removeAt(0).complete(line);
  }

  void _onGone(String reason) {
    if (!_alive) return;
    _alive = false;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(_HelperUnavailable(reason));
    for (final waiter in _waiting) {
      if (!waiter.isCompleted) waiter.completeError(_HelperUnavailable(reason));
    }
    _waiting.clear();
    _socket = null;
    _process = null;
  }

  Future<String> request(String action, Map<String, dynamic> payload) async {
    final socket = _socket;
    if (!alive || socket == null) throw _HelperUnavailable('The helper is not running.');

    final waiter = Completer<String>();
    _waiting.add(waiter);

    try {
      socket.write('${jsonEncode(<String, dynamic>{'a': action, 'p': payload})}\n');
      await socket.flush();
    } catch (e) {
      _waiting.remove(waiter);
      _onGone('The helper could not be written to.');
      throw _HelperUnavailable('The helper could not be written to: $e');
    }

    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _waiting.remove(waiter);
      // A timed-out request leaves the stream out of step with the replies, so
      // the process is discarded rather than trusted for the next call.
      _kill();
      throw _HelperUnavailable('The helper did not respond in time.');
    }
  }

  void _kill() {
    _onGone('The helper was restarted.');
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
  }

  void dispose() {
    _lines?.cancel();
    _lines = null;
    _onGone('The helper was shut down.');
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    try {
      _listener?.close();
    } catch (_) {}
    _listener = null;
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
  }
}

class HelperException implements Exception {
  HelperException(this.message, [this.detail]);
  final String message;
  final String? detail;

  @override
  String toString() => message;
}
