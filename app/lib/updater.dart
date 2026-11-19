import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Installed version, injected at build time from pubspec (see build-apk.yml).
const kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');
const kRepo = 'kevinanuels/Call-In-Apps';
const _ch = MethodChannel('poc_call/update');

class UpdateInfo {
  final String version;
  final String url;
  final int size;
  final String notes;
  UpdateInfo(this.version, this.url, this.size, this.notes);
}

bool _isNewer(String a, String b) {
  List<int> p(String v) =>
      v.split('+').first.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final x = p(a), y = p(b);
  for (var i = 0; i < 3; i++) {
    final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi;
  }
  return false;
}

/// Looks at the latest GitHub release; returns info if it is newer than this app.
Future<UpdateInfo?> checkForUpdate() async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await c.getUrl(Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('User-Agent', 'poc-call-app');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final version = (j['tag_name'] as String).replaceFirst(RegExp(r'^[vV]'), '');
    if (!_isNewer(version, kAppVersion)) return null;
    for (final a in (j['assets'] as List).cast<Map<String, dynamic>>()) {
      if ((a['name'] as String).toLowerCase().endsWith('.apk')) {
        return UpdateInfo(version, a['browser_download_url'] as String,
            (a['size'] as num?)?.toInt() ?? 0, (j['body'] as String?)?.trim() ?? '');
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

/// Downloads the APK into the app cache; reports progress 0..1. Returns the file path.
Future<String> downloadApk(UpdateInfo u, void Function(double) onProgress) async {
  final dir = await _ch.invokeMethod<String>('cacheDir');
  final file = File('$dir/update.apk');
  if (await file.exists()) await file.delete();
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await c.getUrl(Uri.parse(u.url)); // GitHub redirects to its CDN; followed automatically
    req.headers.set('User-Agent', 'poc-call-app');
    final res = await req.close();
    if (res.statusCode != 200) throw 'Download failed (HTTP ${res.statusCode})';
    final total = res.contentLength > 0 ? res.contentLength : u.size;
    final sink = file.openWrite();
    var got = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    if (u.size > 0 && got != u.size) throw 'Download incomplete ($got of ${u.size} bytes)';
    return file.path;
  } finally {
    c.close(force: true);
  }
}

/// Hands the APK to Android's installer. Returns 'started' or 'needs_permission'.
Future<String> installApk(String path) async =>
    (await _ch.invokeMethod<String>('installApk', {'path': path})) ?? 'started';
