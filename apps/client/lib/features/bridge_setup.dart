import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

class BridgeSetupCard extends StatelessWidget {
  final bool supported;
  const BridgeSetupCard({super.key, required this.supported});
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
                const Icon(Icons.usb_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.t('usbSetupTitle'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(strings.t(supported ? 'usbSetupIntro' : 'usbUnsupported')),
            const SizedBox(height: 12),
            Text(strings.t('usbSetupSteps')),
            const SizedBox(height: 12),
            Text(
              strings.t('usbScope'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Keep connection progress beside the clicked control, including on small screens.
class UsbConnectionStatus extends StatelessWidget {
  final String message;
  final bool busy;
  const UsbConnectionStatus({
    super.key,
    required this.message,
    required this.busy,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
}
