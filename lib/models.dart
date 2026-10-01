import 'dart:convert';

/// The two ways this app can run the hotspot.
enum HotspotMode {
  /// Share the PC's internet connection. This is what Windows does by default.
  normal('normal', 'Normal', 'Devices get internet through your Wi-Fi.'),

  /// Hotspot is on, but devices cannot reach the internet.
  noInternet('nointernet', 'No internet', 'Hotspot is on, but devices get no internet.');

  const HotspotMode(this.wire, this.title, this.blurb);

  /// Value understood by the PowerShell helper.
  final String wire;
  final String title;
  final String blurb;

  static HotspotMode fromWire(String? value) {
    for (final mode in HotspotMode.values) {
      if (mode.wire == value) return mode;
    }
    return HotspotMode.normal;
  }
}

/// Friendly names for the WinRT band enum.
const List<String> kBands = <String>['Auto', 'TwoPointFourGigahertz', 'FiveGigahertz'];

String bandLabel(String wire) {
  switch (wire) {
    case 'TwoPointFourGigahertz':
      return '2.4 GHz';
    case 'FiveGigahertz':
      return '5 GHz';
    case 'SixGigahertz':
      return '6 GHz';
    default:
      return 'Auto';
  }
}

String? _str(dynamic v) => v?.toString();

int _int(dynamic v) => v is num ? v.toInt() : 0;

List<String> _strings(dynamic v) =>
    v is List ? v.map((e) => e.toString()).toList(growable: false) : const <String>[];

/// Reduces every notation Windows and a router might use down to bare hex, so a
/// device keeps the same identity whichever way its address is reported.
String normalizeMac(String? raw) =>
    (raw ?? '').replaceAll(RegExp('[^0-9A-Fa-f]'), '').toLowerCase();

/// `aabbccddeeff` -> `AA:BB:CC:DD:EE:FF`, for showing to a person.
String macLabel(String? mac) {
  final hex = normalizeMac(mac).toUpperCase();
  if (hex.isEmpty) return 'unknown device';
  final buffer = StringBuffer();
  for (var i = 0; i < hex.length; i += 2) {
    if (i > 0) buffer.write(':');
    buffer.write(hex.substring(i, i + 2 > hex.length ? hex.length : i + 2));
  }
  return buffer.toString();
}

/// A device that is on the hotspot right now.
class HotspotClient {
  const HotspotClient({required this.mac, this.ip, this.blocked = false});

  /// Bare hex, used as the identity everywhere.
  final String mac;

  /// Address on the hotspot subnet, when it has one yet.
  final String? ip;

  final bool blocked;

  String get label => macLabel(mac);

  factory HotspotClient.fromJson(Map<String, dynamic> json, {Set<String> blocked = const {}}) {
    final mac = normalizeMac(_str(json['mac']));
    return HotspotClient(
      mac: mac,
      ip: _str(json['ip']),
      blocked: blocked.contains(mac),
    );
  }
}

/// A snapshot of everything the helper could find out about the hotspot.
class HotspotStatus {
  const HotspotStatus({
    required this.elevated,
    required this.on,
    required this.state,
    required this.clients,
    required this.ssid,
    required this.band,
    required this.auth,
    required this.passphrase,
    required this.source,
    required this.nic,
    required this.subnet,
    required this.wifiPresent,
    required this.wifiAlias,
    required this.wifiStatus,
    required this.internetAvailable,
    required this.internetProfile,
    required this.firewallApplied,
    required this.firewallRules,
    required this.standaloneSources,
    required this.noConnectionsTimeout,
    required this.icsRunning,
    required this.notes,
    this.clientList = const <HotspotClient>[],
    this.blocked = const <String>[],
    this.sourceHint,
  });

  final bool elevated;
  final bool on;
  final String state;
  final int clients;
  final String? ssid;
  final String? band;

  /// WPA flavour Windows is currently using, e.g. `Wpa2`.
  final String? auth;

  /// The live hotspot password as Windows reports it. Used to show the real
  /// current settings instead of whatever we last remembered.
  final String? passphrase;

  final String? source;
  final String? nic;
  final String subnet;

  final bool wifiPresent;
  final String wifiAlias;
  final String wifiStatus;

  final bool internetAvailable;
  final String? internetProfile;

  final bool firewallApplied;
  final List<String> firewallRules;
  final List<String> standaloneSources;
  final bool? noConnectionsTimeout;
  final bool icsRunning;
  final List<String> notes;

  /// Devices on the hotspot right now.
  final List<HotspotClient> clientList;

  /// Every device currently refused, whether or not it is connected at the
  /// moment. This is the list the user manages, so it outlives any one session.
  final List<String> blocked;

  /// The connection the hotspot was last seen on. Passed back to the helper as a
  /// hint so polling does not have to walk every profile on the PC.
  final String? sourceHint;

  bool get wifiUp => wifiStatus.toLowerCase() == 'up';

  /// Replaces the refused list and re-marks whoever is connected, so the change
  /// shows the moment the helper confirms it rather than on the next poll.
  HotspotStatus copyWithBlocked(List<String> macs) => HotspotStatus(
        elevated: elevated,
        on: on,
        state: state,
        clients: clients,
        ssid: ssid,
        band: band,
        auth: auth,
        passphrase: passphrase,
        source: source,
        nic: nic,
        subnet: subnet,
        wifiPresent: wifiPresent,
        wifiAlias: wifiAlias,
        wifiStatus: wifiStatus,
        internetAvailable: internetAvailable,
        internetProfile: internetProfile,
        firewallApplied: firewallApplied,
        firewallRules: firewallRules,
        standaloneSources: standaloneSources,
        noConnectionsTimeout: noConnectionsTimeout,
        icsRunning: icsRunning,
        notes: notes,
        clientList: clientList
            .map((client) => HotspotClient(
                  mac: client.mac,
                  ip: client.ip,
                  blocked: macs.contains(client.mac),
                ))
            .toList(growable: false),
        blocked: macs,
        sourceHint: sourceHint,
      );

  static HotspotStatus empty() => const HotspotStatus(
        elevated: false,
        on: false,
        state: 'Off',
        clients: 0,
        ssid: null,
        band: null,
        auth: null,
        passphrase: null,
        source: null,
        nic: null,
        subnet: '192.168.137.0/24',
        wifiPresent: false,
        wifiAlias: '',
        wifiStatus: 'Unknown',
        internetAvailable: false,
        internetProfile: null,
        firewallApplied: false,
        firewallRules: <String>[],
        standaloneSources: <String>[],
        noConnectionsTimeout: null,
        icsRunning: false,
        notes: <String>[],
      );

  /// Folds a cheap [QuickState] read into this fuller snapshot, so the fast poll
  /// can refresh what changes often without paying for the slow status action.
  ///
  /// The fast read only knows hardware addresses, so any address or block state
  /// from the last full read is carried over rather than thrown away.
  HotspotStatus withQuick(QuickState quick) {
    // Nothing could be read about the hotspot at all. Only the facts that came
    // from outside that read are worth carrying over; taking the rest would put
    // "Off" on screen just because Windows could not be asked.
    if (!quick.known) {
      return HotspotStatus(
        elevated: quick.elevated ?? elevated,
        on: on,
        state: state,
        clients: clients,
        ssid: ssid,
        band: band,
        auth: auth,
        passphrase: passphrase,
        source: quick.source ?? source,
        nic: nic,
        subnet: subnet,
        wifiPresent: quick.wifiKnown ?? wifiPresent,
        wifiAlias: quick.wifiAlias ?? wifiAlias,
        wifiStatus: quick.wifiStatus ?? wifiStatus,
        internetAvailable: internetAvailable,
        internetProfile: internetProfile,
        firewallApplied: firewallApplied,
        firewallRules: firewallRules,
        standaloneSources: standaloneSources,
        noConnectionsTimeout: noConnectionsTimeout,
        icsRunning: icsRunning,
        notes: notes,
        clientList: clientList,
        blocked: blocked,
        sourceHint: quick.source ?? sourceHint,
      );
    }
    return HotspotStatus(
        elevated: quick.elevated ?? elevated,
        on: quick.on,
        state: quick.state,
        clients: quick.clients,
        ssid: quick.ssid ?? ssid,
        band: quick.band ?? band,
        auth: auth,
        passphrase: quick.passphrase ?? passphrase,
        source: quick.source ?? source,
        nic: nic,
        subnet: subnet,
        wifiPresent: quick.wifiKnown ?? wifiPresent,
        wifiAlias: quick.wifiAlias ?? wifiAlias,
        wifiStatus: quick.wifiStatus ?? wifiStatus,
        internetAvailable: internetAvailable,
        internetProfile: internetProfile,
        firewallApplied: firewallApplied,
        firewallRules: firewallRules,
        standaloneSources: standaloneSources,
        noConnectionsTimeout: noConnectionsTimeout,
        icsRunning: icsRunning,
        notes: notes,
        clientList: _mergeClients(
          quick.clientMacs,
          quick.clientIps,
          clientList,
          blocked.toSet(),
        ),
        blocked: blocked,
        sourceHint: quick.source ?? sourceHint,
      );
  }

  /// Keeps whatever the last full read knew about addresses, dropping devices
  /// that have left and adding any that are new.
  ///
  /// A device that just joined is in the cheap read the moment it appears, so its
  /// address is taken from there when it is known and only falls back to the last
  /// full read otherwise. That is what makes a phone show up complete rather than
  /// sitting there as a bare hardware address until the next slow sweep.
  static List<HotspotClient> _mergeClients(
    List<String> macs,
    Map<String, String> freshIps,
    List<HotspotClient> known,
    Set<String> blocked,
  ) {
    final previous = <String, HotspotClient>{for (final c in known) c.mac: c};
    return macs.map((mac) {
      return HotspotClient(
        mac: mac,
        ip: freshIps[mac] ?? previous[mac]?.ip,
        blocked: blocked.contains(mac),
      );
    }).toList(growable: false);
  }

  factory HotspotStatus.fromJson(Map<String, dynamic> json) {
    final hotspot = (json['hotspot'] as Map?)?.cast<String, dynamic>() ?? const {};
    final wifi = (json['wifi'] as Map?)?.cast<String, dynamic>() ?? const {};
    final internet = (json['internet'] as Map?)?.cast<String, dynamic>() ?? const {};
    final firewall = (json['firewall'] as Map?)?.cast<String, dynamic>() ?? const {};

    final blocked = _strings(json['blocked']).map(normalizeMac).toList(growable: false);
    final blockedSet = blocked.toSet();
    final rawClients = hotspot['clientList'];

    return HotspotStatus(
      elevated: json['elevated'] == true,
      on: hotspot['on'] == true,
      state: _str(hotspot['state']) ?? 'Off',
      clients: _int(hotspot['clients']),
      ssid: _str(hotspot['ssid']),
      band: _str(hotspot['band']),
      auth: _str(hotspot['auth']),
      passphrase: _str(hotspot['passphrase']),
      source: _str(hotspot['source']),
      nic: _str(hotspot['nic']),
      subnet: _str(hotspot['subnet']) ?? '192.168.137.0/24',
      wifiPresent: wifi['present'] == true,
      wifiAlias: _str(wifi['alias']) ?? '',
      wifiStatus: _str(wifi['status']) ?? 'Unknown',
      internetAvailable: internet['available'] == true,
      internetProfile: _str(internet['profile']),
      firewallApplied: firewall['applied'] == true,
      firewallRules: _strings(firewall['rules']),
      standaloneSources: _strings(json['standaloneSources']),
      noConnectionsTimeout: json['noConnectionsTimeout'] == null
          ? null
          : json['noConnectionsTimeout'] == true,
      icsRunning: json['icsRunning'] == true,
      notes: _strings(json['notes']),
      clientList: rawClients is List
          ? rawClients
              .whereType<Map>()
              .map((entry) => HotspotClient.fromJson(
                    entry.cast<String, dynamic>(),
                    blocked: blockedSet,
                  ))
              .where((client) => client.mac.isNotEmpty)
              .toList(growable: false)
          : const <HotspotClient>[],
      blocked: blocked,
      sourceHint: _str(hotspot['source']),
    );
  }
}

/// The handful of facts that change moment to moment, read by the cheap helper
/// action so the UI can keep up with the hotspot without a full status sweep.
class QuickState {
  const QuickState({
    required this.known,
    required this.state,
    required this.on,
    required this.clients,
    this.elevated,
    this.wifiKnown,
    this.wifiAlias,
    this.wifiStatus,
    this.ssid,
    this.band,
    this.passphrase,
    this.source,
    this.clientMacs = const <String>[],
    this.clientIps = const <String, String>{},
  });

  /// False when Windows could not find a hotspot-capable profile at all, which is
  /// different from "the hotspot is off".
  final bool known;
  final String state;
  final bool on;
  final int clients;

  /// Whether the helper is running elevated. Carried on the cheap read so the
  /// app can ask for permission - or decide not to - without waiting for the
  /// slow sweep first, which costs several seconds on a cold start.
  final bool? elevated;

  /// Whether a Wi-Fi adapter could be read at all. False means "no adapter
  /// found", which is different from "the adapter is switched off", so the two
  /// are reported separately.
  final bool? wifiKnown;
  final String? wifiAlias;
  final String? wifiStatus;
  final String? ssid;

  /// The band and passphrase Windows currently has. Read from the same access
  /// point configuration as the name, so carrying them here costs nothing and
  /// lets a change show up within one fast poll rather than waiting for the slow
  /// sweep.
  final String? band;
  final String? passphrase;
  final String? source;

  /// Hardware addresses of whoever is connected. Cheap enough to read on every
  /// poll, so the device list stays live.
  final List<String> clientMacs;

  /// Address on the hotspot subnet for the devices in [clientMacs], when the
  /// helper could resolve one. Also cheap: it reads the neighbour table directly.
  final Map<String, String> clientIps;

  factory QuickState.fromJson(Map<String, dynamic> json) {
    final wifi = (json['wifi'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final raw = json['clientList'];
    final macs = <String>[];
    final ips = <String, String>{};
    if (raw is List) {
      for (final entry in raw.whereType<Map>()) {
        final mac = normalizeMac(_str(entry['mac']));
        if (mac.isEmpty) continue;
        macs.add(mac);
        final ip = _str(entry['ip']);
        if (ip != null && ip.isNotEmpty) ips[mac] = ip;
      }
    }
    return QuickState(
      known: json['known'] == true,
      state: _str(json['state']) ?? 'Off',
      on: json['on'] == true,
      clients: _int(json['clients']),
      elevated: json['elevated'] == null ? null : json['elevated'] == true,
      wifiKnown: wifi['known'] == null ? null : wifi['known'] == true,
      wifiAlias: _str(wifi['alias']),
      wifiStatus: _str(wifi['status']),
      ssid: _str(json['ssid']),
      band: _str(json['band']),
      passphrase: _str(json['passphrase']),
      source: _str(json['source']),
      clientMacs: macs,
      clientIps: ips,
    );
  }
}

/// Result of one helper call.
class HelperResult {
  HelperResult.ok(this.data) : error = null, line = null;
  HelperResult.fail(this.error, [this.line]) : data = const <String, dynamic>{};

  final Map<String, dynamic> data;
  final String? error;
  final String? line;

  bool get ok => error == null;

  /// Human readable summary the UI can log verbatim.
  String get detail {
    if (!ok) return error!;
    final text = data['detail'];
    return text == null ? 'Done.' : text.toString();
  }

  List<String> get notes => data['notes'] is List
      ? (data['notes'] as List).map((e) => e.toString()).toList(growable: false)
      : const <String>[];

  factory HelperResult.parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return HelperResult.fail('Unexpected reply from the helper.');
      final map = decoded.cast<String, dynamic>();
      if (map['ok'] == true) return HelperResult.ok(map);
      return HelperResult.fail(
        (map['error'] ?? 'The helper reported an unknown error.').toString(),
        map['line']?.toString(),
      );
    } catch (e) {
      return HelperResult.fail('Could not read the helper reply: $e');
    }
  }
}