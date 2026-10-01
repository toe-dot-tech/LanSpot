@Tags(['windows-only'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotspot_control/hotspot_service.dart';

/// End-to-end check that the bundled PowerShell helper is reachable, gets
/// unpacked from the Flutter assets, and returns a reply this app can read.
void main() {
  // rootBundle needs the services binding to read the app's assets.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the helper answers a status query', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows only');
      return;
    }

    final service = HotspotService(timeout: const Duration(minutes: 2));
    addTearDown(service.dispose);
    final status = await service.status();

    expect(status.wifiPresent, isTrue, reason: 'a Wi-Fi adapter should be found');
    expect(status.wifiAlias, isNotEmpty);
    expect(status.wifiStatus, isNotEmpty);
    expect(status.subnet, isNotEmpty);
    // The hotspot may well be running on this machine while the tests run, so the
    // on/off state is not asserted. What must hold either way is that a tethering
    // profile was found and the state is a real one rather than "unknown".
    expect(status.state, isNot(equals('Unknown')));
    // Windows always has a stored access point configuration, even when the
    // hotspot is off, so these must come back populated.
    expect(status.ssid, isNotEmpty, reason: 'Windows should report its stored SSID');
    expect(status.band, isNotEmpty);
    expect(status.auth, isNotEmpty);
    expect(status.passphrase, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the quick action is much faster than the full status', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows only');
      return;
    }

    final service = HotspotService(timeout: const Duration(minutes: 2));
    addTearDown(service.dispose);

    // Warm up first. Both timings swing with machine load, so only the
    // comparison between them is a stable thing to assert on.
    await service.quick();

    final slowWatch = Stopwatch()..start();
    final full = await service.status();
    slowWatch.stop();

    final fastWatch = Stopwatch()..start();
    final quick = await service.quick();
    fastWatch.stop();

    expect(quick.known, isTrue, reason: 'Windows should report a tethering profile');
    expect(quick.on, full.on);
    expect(quick.clients, full.clients);
    expect(quick.ssid, full.ssid);

    // The whole point of the quick action is that it skips the firewall sweep
    // and the NetAdapter module loads, which dominate a full status.
    expect(
      fastWatch.elapsedMilliseconds,
      lessThan(slowWatch.elapsedMilliseconds ~/ 2),
      reason: 'quick took ${fastWatch.elapsedMilliseconds}ms but '
          'status took ${slowWatch.elapsedMilliseconds}ms',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('repeated quick polls reuse one helper process and stay fast', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows only');
      return;
    }

    final service = HotspotService(timeout: const Duration(minutes: 2));
    addTearDown(service.dispose);

    // First call pays the process start and the module loads.
    await service.quick();

    final watch = Stopwatch()..start();
    for (var i = 0; i < 8; i++) {
      final quick = await service.quick();
      expect(quick.known, isTrue);
    }
    watch.stop();

    // A fresh PowerShell process costs ~400ms before it runs anything, so eight
    // separate processes could not possibly finish inside a second. The only way
    // this passes is if all eight went to the same, already-warm process.
    expect(
      watch.elapsedMilliseconds,
      lessThan(1200),
      reason: '8 warm polls took ${watch.elapsedMilliseconds}ms, which suggests '
          'a new process was started per call',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('configuring with nothing supplied leaves Windows alone', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows only');
      return;
    }

    final service = HotspotService(timeout: const Duration(minutes: 2));
    addTearDown(service.dispose);
    final before = await service.status();

    // An empty payload must be a no-op. The old code pushed a fresh config with
    // default values here, which wiped whatever Windows had.
    final result = await service.call('configure', const <String, dynamic>{});
    expect(result.ok, isTrue, reason: result.error ?? '');

    final after = await service.status();
    expect(after.ssid, before.ssid);
    expect(after.passphrase, before.passphrase);
    expect(after.band, before.band);
    expect(after.auth, before.auth);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('changing one field leaves the others alone', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows only');
      return;
    }

    final service = HotspotService(timeout: const Duration(minutes: 2));
    addTearDown(service.dispose);
    final before = await service.status();

    // Flip the band only. The SSID, password and auth kind must survive, since
    // the helper copies every untouched field out of Windows first.
    final wanted = before.band == 'TwoPointFourGigahertz' ? 'FiveGigahertz' : 'TwoPointFourGigahertz';
    final result = await service.call('configure', <String, dynamic>{'band': wanted});
    expect(result.ok, isTrue, reason: result.error ?? '');

    final changed = await service.status();
    expect(changed.band, wanted);
    expect(changed.ssid, before.ssid, reason: 'the SSID must not be touched by a band change');
    expect(changed.passphrase, before.passphrase, reason: 'the password must not be touched by a band change');
    expect(changed.auth, before.auth);

    // Put the band back so repeated runs start from the same place.
    final restore = await service.call('configure', <String, dynamic>{'band': before.band!});
    expect(restore.ok, isTrue, reason: restore.error ?? '');
  }, timeout: const Timeout(Duration(minutes: 5)));
}