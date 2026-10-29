import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

/// Shows the active account without allowing long addresses to overflow the header.
class AccountIdentity extends StatelessWidget {
  final String email;
  final bool compact;
  final bool sidebar;
  const AccountIdentity({
    super.key,
    required this.email,
    this.compact = false,
    this.sidebar = false,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final color = Theme.of(context).colorScheme.primary;
    if (sidebar) {
      return Container(
        key: const ValueKey('sidebarAccount'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: color.withValues(alpha: .12),
                  child: Text(
                    email.isEmpty ? 'C' : email[0].toUpperCase(),
                    style: TextStyle(color: color, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.t('currentAccount'),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              email,
              key: const ValueKey('sidebarAccountEmail'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    return PopupMenuButton<void>(
      key: const ValueKey('accountIdentity'),
      tooltip: email.isEmpty ? strings.t('currentAccount') : email,
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 440.0),
      ),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.t('currentAccount'),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              SelectableText(
                email,
                key: const ValueKey('accountEmailDetails'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact && email.isNotEmpty) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 12),
            ],
            CircleAvatar(
              radius: 17,
              backgroundColor: color.withValues(alpha: .12),
              child: Text(
                email.isEmpty ? 'C' : email[0].toUpperCase(),
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
