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
