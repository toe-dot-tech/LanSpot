import 'package:flutter_test/flutter_test.dart';

import 'package:lanspot/models.dart';

void main() {
  test('modes round trip through their wire names', () {
    for (final mode in HotspotMode.values) {
      expect(HotspotMode.fromWire(mode.wire), mode);
    }
    expect(HotspotMode.fromWire(null), HotspotMode.normal);
    expect(HotspotMode.fromWire('nonsense'), HotspotMode.normal);
  });

  test('the removed offline mode falls back to normal', () {
    // A settings.json written by an older build may still name "offline".
    expect(HotspotMode.fromWire('offline'), HotspotMode.normal);
    expect(HotspotMode.values, <HotspotMode>[
      HotspotMode.normal,
      HotspotMode.noInternet,
    ]);
  });

  test('a device is identified however its address is written', () {
    expect(normalizeMac('AA:BB:CC:DD:EE:FF'), 'aabbccddeeff');
    expect(normalizeMac('aa-bb-cc-dd-ee-ff'), 'aabbccddeeff');
    expect(normalizeMac('AABBCCDDEEFF'), 'aabbccddeeff');
    expect(normalizeMac('{AA=BB;CC=DD;EE=FF}'), 'aabbccddeeff');
    expect(normalizeMac(null), '');
    expect(macLabel('aabbccddeeff'), 'AA:BB:CC:DD:EE:FF');
  });

  test('the blocked list is read and matched against connected devices', () {
    final status = HotspotStatus.fromJson(<String, dynamic>{
      'ok': true,
      'hotspot': <String, dynamic>{
        'on': true,
        'state': 'On',
        'clients': 2,
        'clientList': <Map<String, dynamic>>[
          <String, dynamic>{'mac': 'AA:BB:CC:DD:EE:01', 'ip': '192.168.137.11'},
          <String, dynamic>{'mac': 'aa:bb:cc:dd:ee:02', 'ip': '192.168.137.12'},
        ],
      },
      // Windows may report the separator differently to the tethering API.
      'blocked': <String>['AA-BB-CC-DD-EE-02'],
    });

    expect(status.blocked, <String>['aabbccddee02']);
    expect(status.clientList.map((c) => c.mac), <String>[
      'aabbccddee01',
      'aabbccddee02',
    ]);
    expect(status.clientList.first.blocked, isFalse);
    expect(status.clientList.last.blocked, isTrue);
    expect(status.clientList.last.label, 'AA:BB:CC:DD:EE:02');
  });

  test('the fast poll keeps addresses and block state from the last full read', () {
    final full = HotspotStatus.fromJson(<String, dynamic>{
      'ok': true,
      'hotspot': <String, dynamic>{
        'on': true,
        'state': 'On',
        'clients': 2,
        'ssid': 'Office',
        'clientList': <Map<String, dynamic>>[
          <String, dynamic>{'mac': 'aabbccddee01', 'ip': '192.168.137.11'},
          <String, dynamic>{'mac': 'aabbccddee02', 'ip': '192.168.137.12'},
        ],
      },
      'blocked': <String>['aabbccddee02'],
    });

    // The cheap read only knows addresses, so the merged result must not lose
    // what the expensive read knew.
    final merged = full.withQuick(const QuickState(
      known: true,
      state: 'On',
      on: true,
      clients: 1,
      clientMacs: <String>['aabbccddee01'],
    ));

    expect(merged.clients, 1);
    expect(merged.clientList, hasLength(1));
    expect(merged.clientList.single.mac, 'aabbccddee01');
    expect(merged.clientList.single.ip, '192.168.137.11');
    expect(merged.clientList.single.blocked, isFalse);
    // Still blocked even though it has left, which is the whole point.
    expect(merged.blocked, <String>['aabbccddee02']);
  });

  test('replacing the blocked list re-marks whoever is connected', () {
    final full = HotspotStatus.fromJson(<String, dynamic>{
      'ok': true,
      'hotspot': <String, dynamic>{
        'clientList': <Map<String, dynamic>>[
          <String, dynamic>{'mac': 'aabbccddee01', 'ip': '192.168.137.11'},
        ],
      },
    });

    final blocked = full.copyWithBlocked(const <String>['aabbccddee01']);
    expect(blocked.clientList.single.blocked, isTrue);

    final cleared = blocked.copyWithBlocked(const <String>[]);
    expect(cleared.clientList.single.blocked, isFalse);
    expect(cleared.blocked, isEmpty);
  });

  test('status parses the helper payload', () {
    final status = HotspotStatus.fromJson(<String, dynamic>{
      'ok': true,
      'elevated': true,
      'hotspot': <String, dynamic>{
        'on': true,
        'state': 'On',
        'clients': 2,
        'ssid': 'MyHotspot',
        'band': 'FiveGigahertz',
        'auth': 'Wpa2',
        'passphrase': 'liveSecret1',
        'source': 'Home',
        'subnet': '192.168.137.0/24',
      },
      'wifi': <String, dynamic>{'present': true, 'alias': 'Wi-Fi', 'status': 'Up'},
      'internet': <String, dynamic>{'available': true, 'profile': 'Home'},
      'firewall': <String, dynamic>{'applied': true, 'rules': <String>['rule-a']},
      'standaloneSources': <String>['vEthernet (Default Switch)'],
      'notes': <String>[],
    });

    expect(status.on, isTrue);
    expect(status.clients, 2);
    expect(status.band, 'FiveGigahertz');
    expect(bandLabel(status.band!), '5 GHz');
    expect(status.wifiUp, isTrue);
    expect(status.firewallApplied, isTrue);
    expect(status.standaloneSources, hasLength(1));
    expect(status.sourceHint, 'Home');
    expect(status.auth, 'Wpa2');
    expect(status.passphrase, 'liveSecret1');
  });

  test('status tolerates a payload with no live access point config', () {
    // Before the first successful status call the hotspot block is absent, which
    // must not throw.
    final status = HotspotStatus.fromJson(<String, dynamic>{'ok': true});
    expect(status.on, isFalse);
    expect(status.auth, isNull);
    expect(status.passphrase, isNull);
    expect(status.ssid, isNull);
  });

  test('helper failures surface the message', () {
    final result = HelperResult.parse('{"ok":false,"error":"boom","line":"12: x"}');
    expect(result.ok, isFalse);
    expect(result.error, 'boom');
    expect(result.line, '12: x');

    final good = HelperResult.parse('{"ok":true,"detail":"all good"}');
    expect(good.ok, isTrue);
    expect(good.detail, 'all good');

    expect(HelperResult.parse('not json').ok, isFalse);
  });
}