import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

const bridgeDownloadPath = '/downloads/circuitlab-bridge-windows.exe';

/// The companion connects to the same API as the client, including custom hosts.
Uri bridgeSocketUri(Uri api) => api.replace(
  scheme: api.scheme == 'https' ? 'wss' : 'ws',
  path: '${api.path.replaceFirst(RegExp(r'/+$'), '')}/devices/connect',
  query: null,
  fragment: null,
);

class BridgeSetupCard extends StatelessWidget {
  final VoidCallback onDownload;
  const BridgeSetupCard({super.key, required this.onDownload});
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.computer_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.t('bridgeSetupTitle'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(strings.t('bridgeInstallHint')),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('download-windows-bridge'),
              onPressed: onDownload,
              icon: const Icon(Icons.download_outlined),
              label: Text(strings.t('downloadWindowsBridge')),
            ),
            const SizedBox(height: 8),
            Text(
              strings.t('bridgeWindowsScope'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            for (final key in [
              'bridgeSetupRegister',
              'bridgeSetupRun',
              'bridgeSetupSession',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(strings.t(key)),
              ),
            Text(
              strings.t('bridgeConnectionMeaning'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
