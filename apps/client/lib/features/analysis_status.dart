import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

class AnalysisStatusBanner extends StatelessWidget {
  final String status;
  final int attempts;
  const AnalysisStatusBanner({
    super.key,
    required this.status,
    this.attempts = 1,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final title = attempts > 0 && status == 'pending'
        ? 'analysisRetrying'
        : status == 'pending'
        ? 'analysisQueued'
        : status == 'submitting'
        ? 'analysisSubmitting'
        : 'analysisInProgress';
    return Semantics(
      liveRegion: true,
      label: strings.t(title),
      child: Container(
        key: const ValueKey('analysis-status-banner'),
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .08),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .4),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.t(title),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(strings.t('analysisProgressNotice')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
