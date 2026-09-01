import 'dart:io';

import 'package:flutter/services.dart';

/// Wi-Fi automation for the offline match (platform channel).
///
/// Android host: starts a local-only hotspot (app-owned, no internet) and
/// returns its generated SSID/passphrase — the QR carries them so guests
/// join with zero Settings trips. iOS cannot start a hotspot
/// programmatically (no public API), so [hostStart] returns null there and
/// the lobby falls back to explaining manual options.
///
/// Guests: [guestJoin] joins the QR's hotspot — Android via
/// WifiNetworkSpecifier (a to-the-point, no-internet connection),
/// iOS via NEHotspotConfiguration (join-once).
class Hotspot {
  static const _ch = MethodChannel('seechess/hotspot');

  /// True after this process joined a hotspot through [guestJoin].
  static bool joined = false;

  static Future<({String ssid, String pass})?> hostStart() async {
    if (!Platform.isAndroid) return null;
    try {
      final cfg = await _ch.invokeMapMethod<String, String?>('hostStart');
      var ssid = cfg?['ssid'];
      final pass = cfg?['pass'];
      if (ssid == null || pass == null) return null;
      // pre-Android-11 configs quote the SSID
      if (ssid.startsWith('"') && ssid.endsWith('"')) {
        ssid = ssid.substring(1, ssid.length - 1);
      }
      return (ssid: ssid, pass: pass);
    } on PlatformException {
      return null; // permission denied / tethering active — manual fallback
    }
  }

  static Future<void> hostStop() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('hostStop');
    } on PlatformException {
      // already gone
    }
  }

  static Future<bool> guestJoin(String ssid, String pass) async {
    try {
      final ok = await _ch.invokeMethod<bool>('guestJoin', {
        'ssid': ssid,
        'pass': pass,
      });
      joined = ok ?? false;
      return joined;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> guestLeave() async {
    if (!joined) return;
    joined = false;
    try {
      await _ch.invokeMethod<void>('guestLeave');
    } on PlatformException {
      // nothing to release
    }
  }
}
