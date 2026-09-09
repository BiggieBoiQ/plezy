import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// Downloads a release APK and hands it to the system package installer.
///
/// The fork's Android self-update path. Android has no Sparkle equivalent, and
/// a truly silent install needs device-owner privileges this app will never
/// hold, so the goal here is narrower: never send the viewer to a browser. The
/// app fetches the APK itself and the installer opens straight onto its
/// confirmation screen, which is two remote clicks on a TV.
class ApkUpdateInstaller {
  static const MethodChannel _channel = MethodChannel('com.plezy/apk_install');

  /// Whether the OS will let this app open the package installer.
  ///
  /// False when the viewer has not yet allowed the app as an unknown source.
  /// Below Android O the permission is granted at install time and this is
  /// always true.
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canRequestInstalls') ?? false;
    } on PlatformException catch (error, stackTrace) {
      appLogger.e('Failed to query install permission', error: error, stackTrace: stackTrace);
      return false;
    }
  }

  /// Opens the OS screen where the app can be allowed as an unknown source.
  ///
  /// Returns false when the device has no such screen, which happens on plenty
  /// of Android TV builds; callers should say where to look rather than treat
  /// it as a failed update.
  static Future<bool> openPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openInstallPermissionSettings') ?? false;
    } on PlatformException catch (error, stackTrace) {
      appLogger.e('Failed to open install permission settings', error: error, stackTrace: stackTrace);
      return false;
    }
  }

  /// Downloads [url] into the cache directory, reporting 0..1 progress.
  ///
  /// Returns the downloaded file, or null if the download failed. The file is
  /// written to a `.part` path and renamed only once the body is complete, so a
  /// connection dropped mid-transfer can never be handed to the installer as a
  /// truncated APK.
  static Future<File?> downloadApk(
    String url, {
    required String version,
    void Function(double progress)? onProgress,
    http.Client? client,
  }) async {
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;

    try {
      final dir = await getApplicationCacheDirectory();
      final target = File('${dir.path}/plezy-$version.apk');
      final partial = File('${target.path}.part');

      if (await target.exists()) await target.delete();
      if (await partial.exists()) await partial.delete();

      final request = http.Request('GET', Uri.parse(url));
      final response = await httpClient.send(request);

      if (response.statusCode != 200) {
        appLogger.e('APK download failed with HTTP ${response.statusCode}');
        return null;
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = partial.openWrite();

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          // Without a Content-Length there is nothing honest to report, so the
          // caller is left on its indeterminate spinner.
          if (total > 0) onProgress?.call(received / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (total > 0 && received != total) {
        appLogger.e('APK download truncated: got $received of $total bytes');
        await partial.delete();
        return null;
      }

      await partial.rename(target.path);
      return target;
    } catch (error, stackTrace) {
      appLogger.e('APK download failed', error: error, stackTrace: stackTrace);
      return null;
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  /// Hands [apk] to the system package installer.
  static Future<bool> install(File apk) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': apk.path}) ?? false;
    } on PlatformException catch (error, stackTrace) {
      appLogger.e('Failed to launch the package installer', error: error, stackTrace: stackTrace);
      return false;
    }
  }

  /// Removes APKs left behind by earlier updates.
  ///
  /// The installer reads the file after this app has moved on, so cleanup waits
  /// until the next launch rather than deleting straight after handing it over.
  static Future<void> cleanUpDownloads({String? keepVersion}) async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await getApplicationCacheDirectory();
      final keep = keepVersion == null ? null : 'plezy-$keepVersion.apk';
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith('plezy-')) continue;
        if (!name.endsWith('.apk') && !name.endsWith('.apk.part')) continue;
        if (name == keep) continue;
        await entry.delete();
      }
    } catch (error, stackTrace) {
      appLogger.w('Failed to clean up old APK downloads', error: error, stackTrace: stackTrace);
    }
  }
}
