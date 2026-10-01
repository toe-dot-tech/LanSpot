import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Small JSON-file settings store in %APPDATA%\LanSpot\settings.json.
/// Avoids a plugin dependency for something this simple.
class Prefs {
  Prefs._(this._file, this._values);

  final File _file;
  final Map<String, dynamic> _values;

  static const String _defaultSsid = 'DESKTOP-HOTSPOT';

  /// Only ever a starting point for someone who has not set a password yet. The
  /// app does not push this at Windows - the settings Windows already holds are
  /// what get used, and this is only written if the user asks for it.
  static const String _defaultPassword = '12345678';

  /// Read straight away rather than through a future.
  ///
  /// This is a few hundred bytes of local JSON, so the read costs far less than
  /// a frame. Doing it synchronously also means the settings are already in hand
  /// before the first build, instead of the screen showing defaults for a beat
  /// while a future resolves.
  static Prefs load() {
    final root =
        Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? '';
    final dir = Directory('$root${Platform.pathSeparator}LanSpot');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}settings.json');

    Map<String, dynamic> values = <String, dynamic>{};
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) values = decoded.cast<String, dynamic>();
      } catch (_) {
        values = <String, dynamic>{};
      }
    } else {
      // The app was called Hotspot Control before it was renamed. Carry any
      // existing settings across rather than silently resetting someone's
      // network name and password.
      final legacy = File(
        '$root${Platform.pathSeparator}HotspotControl${Platform.pathSeparator}settings.json',
      );
      if (legacy.existsSync()) {
        try {
          final decoded = jsonDecode(legacy.readAsStringSync());
          if (decoded is Map) {
            values = decoded.cast<String, dynamic>();
            file.writeAsStringSync(jsonEncode(values));
          }
        } catch (_) {
          values = <String, dynamic>{};
        }
      }
    }

    return Prefs._(file, values);
  }

  HotspotMode get mode => HotspotMode.fromWire(_values['mode'] as String?);
  set mode(HotspotMode value) => _values['mode'] = value.wire;

  String get ssid => (_values['ssid'] as String?)?.trim().isNotEmpty == true
      ? _values['ssid'] as String
      : _defaultSsid;
  set ssid(String value) => _values['ssid'] = value.trim();

  String get password => (_values['password'] as String?)?.isNotEmpty == true
      ? _values['password'] as String
      : _defaultPassword;
  set password(String value) => _values['password'] = value;

  String get band {
    final value = _values['band'] as String?;
    return kBands.contains(value) ? value! : 'Auto';
  }

  set band(String value) => _values['band'] = value;

  bool get keepAlive => _values['keepAlive'] == true;
  set keepAlive(bool value) => _values['keepAlive'] = value;

  bool get autoStart => _values['autoStart'] == true;
  set autoStart(bool value) => _values['autoStart'] = value;

  /// Light is the default; dark is opt-in from the title bar.
  bool get darkMode => _values['darkMode'] == true;
  set darkMode(bool value) => _values['darkMode'] = value;

  /// Written straight away as well. These are a few hundred bytes, and making
  /// the user wait on a flush before the app acts on what they just asked for
  /// would be a strange trade for a save that takes no time at all.
  void save() {
    try {
      _file.writeAsStringSync(jsonEncode(_values), flush: true);
    } catch (_) {
      // Losing a preference is not worth interrupting the user over.
    }
  }
}