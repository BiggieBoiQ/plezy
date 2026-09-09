import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/apk_update_installer.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'dialogs.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) => _UpdateAvailableDialog(
      updateInfo: updateInfo,
      title: title,
      dismissLabel: dismissLabel,
      showSkipVersion: showSkipVersion,
    ),
  );
}

/// Stateful so the Android path can hold download progress in place.
///
/// Where an APK asset is available the dialog stays put while it downloads and
/// then opens the system installer directly. On a TV the browser hop is the
/// worst part of updating, so it is skipped entirely; every other platform
/// keeps the release-page link.
class _UpdateAvailableDialog extends StatefulWidget {
  const _UpdateAvailableDialog({
    required this.updateInfo,
    required this.title,
    required this.dismissLabel,
    required this.showSkipVersion,
  });

  final Map<String, dynamic> updateInfo;
  final String title;
  final String dismissLabel;
  final bool showSkipVersion;

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  double? _progress;
  bool _downloading = false;
  String? _error;

  String get _latestVersion => widget.updateInfo['latestVersion'] as String;
  String get _releaseUrl => widget.updateInfo['releaseUrl'] as String;
  String? get _apkUrl => widget.updateInfo['apkUrl'] as String?;

  Future<void> _openReleasePage() async {
    final url = Uri.parse(_releaseUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _downloadAndInstall() async {
    final apkUrl = _apkUrl;
    if (apkUrl == null) return _openReleasePage();

    // Checked up front so the failure stays legible: without the permission the
    // installer intent is swallowed by the OS with nothing shown to the viewer.
    if (!await ApkUpdateInstaller.canInstall()) {
      final opened = await ApkUpdateInstaller.openPermissionSettings();
      if (!mounted) return;
      setState(() => _error = opened ? t.update.allowInstallsThenRetry : t.update.allowInstallsManually);
      return;
    }

    setState(() {
      _downloading = true;
      _error = null;
      _progress = null;
    });

    final file = await ApkUpdateInstaller.downloadApk(
      apkUrl,
      version: _latestVersion,
      onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      },
    );

    if (!mounted) return;

    if (file == null) {
      setState(() {
        _downloading = false;
        _error = t.update.downloadFailed;
      });
      return;
    }

    final launched = await ApkUpdateInstaller.install(file);
    if (!mounted) return;

    if (launched) {
      Navigator.pop(context);
    } else {
      setState(() {
        _downloading = false;
        _error = t.update.installFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canInstallInApp = _apkUrl != null;

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .start,
        children: [
          Text(t.update.versionAvailable(version: _latestVersion), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            t.update.currentVersion(version: widget.updateInfo['currentVersion']),
            style: theme.textTheme.bodySmall,
          ),
          if (_downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(
              _progress == null
                  ? t.update.downloading
                  : t.update.downloadingPercent(percent: (_progress! * 100).round().toString()),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
        ],
      ),
      actions: [
        // Every action is withdrawn while the APK is in flight: there is nothing
        // useful to press, and dismissing mid-download would orphan the transfer.
        if (!_downloading) ...[
          DialogActionButton(onPressed: () => Navigator.pop(context), label: widget.dismissLabel),
          if (widget.showSkipVersion)
            DialogActionButton(
              onPressed: () async {
                // Resolved before the await: inside a closure the analyzer
                // cannot tie this State's `mounted` to its context.
                final navigator = Navigator.of(context);
                await UpdateService.skipVersion(_latestVersion);
                if (mounted) navigator.pop();
              },
              label: t.update.skipVersion,
            ),
          DialogActionButton(
            onPressed: canInstallInApp ? _downloadAndInstall : _openReleasePage,
            label: canInstallInApp ? t.update.downloadAndInstall : t.update.viewRelease,
            isPrimary: true,
          ),
        ],
      ],
    );
  }
}
