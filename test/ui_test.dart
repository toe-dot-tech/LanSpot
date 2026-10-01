import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotspot_control/hotspot_service.dart';
import 'package:hotspot_control/main.dart';
import 'package:hotspot_control/models.dart';
import 'package:hotspot_control/prefs.dart';
import 'package:hotspot_control/theme.dart';

/// A stand-in for the PowerShell helper, so layout can be exercised without
/// spawning a process per poll.
class FakeService extends HotspotService {
  FakeService({this.on = false, this.clients = 0, this.macs = const <String>[], this.blocked = const <String>[]});

  bool on;
  int clients;
  List<String> macs;
  List<String> blocked;
  int calls = 0;

  /// Set to make the next action hang, so the busy frame can be inspected.
  Completer<HelperResult>? pending;

  @override
  Future<HotspotStatus> status({String? hint}) async {
    calls++;
    return _snapshot();
  }

  @override
  Future<QuickState> quick({String? hint}) async {
    calls++;
    return QuickState(
      known: true,
      state: on ? 'On' : 'Off',
      on: on,
      clients: clients,
      ssid: 'TOE Tech | App Developer.',
      source: on ? '.' : null,
      clientMacs: macs,
    );
  }

  @override
  Future<HelperResult> call(String action, [Map<String, dynamic> payload = const {}]) async {
    calls++;
    final held = pending;
    if (held != null) return held.future;
    if (action == 'block' || action == 'unblock') {
      final mac = normalizeMac(payload['mac']?.toString());
      blocked = action == 'block'
          ? <String>{...blocked, mac}.toList()
          : blocked.where((m) => m != mac).toList();
      return HelperResult.ok(<String, dynamic>{
        'detail': '$action $mac',
        'blocked': blocked,
      });
    }
    if (action == 'clearblocks') {
      blocked = const <String>[];
      return HelperResult.ok(<String, dynamic>{'detail': 'cleared', 'blocked': blocked});
    }
    return HelperResult.ok(const <String, dynamic>{'detail': 'ok'});
  }

  HotspotStatus _snapshot() => HotspotStatus.fromJson(<String, dynamic>{
        'ok': true,
        'elevated': true,
        'hotspot': <String, dynamic>{
          'on': on,
          'state': on ? 'On' : 'Off',
          'clients': clients,
          'ssid': 'TOE Tech | App Developer.',
          'passphrase': '1234568901',
          'band': 'TwoPointFourGigahertz',
          'auth': 'Wpa2',
          'source': '.',
          'nic': 'Local Area Connection* 9',
          'subnet': '192.168.137.0/24',
          'clientList': <Map<String, dynamic>>[
            for (final mac in macs) <String, dynamic>{'mac': mac, 'ip': '192.168.137.42'},
          ],
        },
        'wifi': <String, dynamic>{'present': true, 'alias': 'Wi-Fi', 'status': 'Up'},
        'internet': <String, dynamic>{'available': true, 'profile': '.'},
        'firewall': <String, dynamic>{'applied': false, 'rules': <String>[]},
        'blocked': blocked,
        'notes': <String>[],
      });
}

/// Sizes worth checking: the real window is 1180x820, and the layout has two
/// breakpoints (the log rail at 1040 and the field stacking at 460).
const Map<String, Size> kSizes = <String, Size>{
  'window 1180x820': Size(1180, 820),
  'rail 1040': Size(1040, 900),
  'no rail 1000': Size(1000, 900),
  'narrow fields 430': Size(430, 900),
  'wide 1600': Size(1600, 1000),
};

void main() {
  for (final entry in kSizes.entries) {
    testWidgets('lays out without overflow at ${entry.key}', (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_Harness(service: FakeService()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shows the hotspot state from the helper', (tester) async {
    _size(tester);

    final service = FakeService();
    await _boot(tester, service);

    expect(_heroState(tester), 'Off');
    expect(find.text('TOE Tech | App Developer.'), findsWidgets);
    expect(find.text('Turn on'), findsOneWidget);
  });

  testWidgets('switches to the dark theme without overflowing', (tester) async {
    _size(tester);

    await _boot(tester, FakeService());

    await tester.tap(find.byTooltip('Switch to dark'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Switch to light'), findsOneWidget);
  });

  testWidgets('shows a live hotspot as on with clients', (tester) async {
    _size(tester);

    await _boot(tester, FakeService(on: true, clients: 3));

    expect(_heroState(tester), 'On');
    expect(find.text('Turn off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only offers the two remaining modes', (tester) async {
    _size(tester);

    await _boot(tester, FakeService());

    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('No internet'), findsOneWidget);
    expect(find.text('Offline hotspot'), findsNothing);
  });

  testWidgets('lists connected devices with a readable address', (tester) async {
    _size(tester);
    await _boot(tester, FakeService(on: true, clients: 1, macs: const <String>['aabbccddeeff']));

    expect(find.text('AA:BB:CC:DD:EE:FF'), findsOneWidget);
    expect(find.text('CONNECTED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocking a device moves it into the blocked group', (tester) async {
    _size(tester);
    await _boot(tester, FakeService(on: true, clients: 1, macs: const <String>['aabbccddeeff']));

    await tester.tap(find.text('AA:BB:CC:DD:EE:FF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('BLOCKED'), findsOneWidget);
    expect(find.textContaining('refused'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the blocked count shows on the devices tab', (tester) async {
    _size(tester);
    await _boot(tester, FakeService(
        on: true,
        clients: 1,
        macs: const <String>['aabbccddeeff', '112233445566'],
        blocked: const <String>['112233445566'],
      ));

    expect(find.text('1'), findsOneWidget);
    expect(find.text('1 (1 blocked)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the activity tab swaps in the log and its actions', (tester) async {
    _size(tester);
    await _boot(tester, FakeService());

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();

    expect(find.text('ACTIVITY'), findsOneWidget);
    expect(find.byTooltip('Copy the log and current status'), findsOneWidget);
    expect(find.byTooltip('Clear the log'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a working frame while an action is in flight', (tester) async {
    _size(tester);
    final service = FakeService();
    service.pending = Completer<HelperResult>();
    await tester.pumpWidget(_Harness(service: service));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Turn on'));
    await tester.pump();

    expect(find.text('working'), findsOneWidget);

    service.pending!.complete(HelperResult.ok(const <String, dynamic>{'detail': 'ok'}));
    await tester.pumpAndSettle();
    expect(find.text('working'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow rail still lays out the device list', (tester) async {
    tester.view.physicalSize = kSizes['narrow fields 430']!;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _boot(tester, FakeService(on: true, clients: 1, macs: const <String>['aabbccddeeff']));

    expect(find.text('AA:BB:CC:DD:EE:FF'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _size(WidgetTester tester) {
  tester.view.physicalSize = kSizes['window 1180x820']!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The hero's own state word, which is what distinguishes "hotspot off" from
/// "Wi-Fi off" in the extras list.
String _heroState(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey<String>('hero-state'))).data!;

/// Mounts the app and lets start-up finish.
///
/// The first thing the page does is read the settings file, which is real
/// asynchronous I/O, so ordinary pumping never gets past it. `runAsync` is the
/// only way to let those real futures complete inside a widget test.
Future<void> _boot(WidgetTester tester, HotspotService service) async {
  await tester.pumpWidget(_Harness(service: service));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

class _Harness extends StatefulWidget {
  const _Harness({required this.service});

  final HotspotService service;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    final tokens = _dark ? Tokens.dark : Tokens.light;
    return MaterialApp(
      theme: buildTheme(tokens),
      home: HomePage(
        skipElevation: true,
        service: widget.service,
        darkMode: _dark,
        // Reads the real settings file but never writes it, so running the
        // tests cannot disturb the installed app's choices.
        prefs: Prefs.load(),
        onToggleTheme: () => setState(() => _dark = !_dark),
      ),
    );
  }
}

