import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constant.dart';

class Preferences {
  static Preferences? _instance;

  Preferences._internal();

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<SharedPreferences?>? _preferencesFuture;

  Future<SharedPreferences?> get _preferences async {
    _preferencesFuture ??= _initPreferences();
    return _preferencesFuture;
  }

  Future<SharedPreferences?> _initPreferences() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<bool> get isInit async => await _preferences != null;

  Future<ClashConfig?> getClashConfig() async {
    final preferences = await _preferences;
    final clashConfigString = preferences?.getString(clashConfigKey);
    if (clashConfigString == null) return null;
    final clashConfigMap = json.decode(clashConfigString);
    return ClashConfig.fromJson(clashConfigMap);
  }

  Future<Config?> getConfig() async {
    final preferences = await _preferences;
    final configString = preferences?.getString(configKey);
    if (configString == null) return null;
    final configMap = json.decode(configString);
    return Config.compatibleFromJson(configMap);
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await _preferences;
    return await preferences?.setString(configKey, json.encode(config)) ??
        false;
  }

  Future<void> clearClashConfig() async {
    final preferences = await _preferences;
    preferences?.remove(clashConfigKey);
  }

  Future<void> clearPreferences() async {
    final preferences = await _preferences;
    preferences?.clear();
  }
}

Preferences get preferences => Preferences();
