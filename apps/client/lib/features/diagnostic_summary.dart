import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

/// Present current findings separately from unconfirmed explanations.
class DiagnosticSummary extends StatelessWidget {
  final Map session;
  final bool technicalDetails;
  const DiagnosticSummary({
    super.key,
    required this.session,
    this.technicalDetails = false,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final plan = session['pending_test'] as Map? ?? {};
    dynamic localized(Map data, String field) =>
        (data['translations'] as Map?)?[strings.language]?[field] ??
        data[field];
    final observations = localized(plan, 'observations') as List? ?? [];
    final hypotheses = (session['hypotheses'] as List? ?? [])
        .where(
          (h) =>
              h['data']['analysis_step'] == session['analysis_steps'] &&
              h['data']['withdrawn_context'] != true,
        )
        .toList();
    if (observations.isEmpty && hypotheses.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('diagnostic-summary'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.t('assessmentAndEvidence'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (observations.isNotEmpty) ExpansionTile(
              key: PageStorageKey('findings-${session['id']}-${session['analysis_steps']}'),
              title: Text(strings.t('recordedFindings')),
              tilePadding: EdgeInsets.zero,
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final observation in observations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.notes_outlined, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(observation.toString())),
                      ],
                    ),
                  ),
              ],
            ),
            if (hypotheses.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                strings.t('possibleExplanations'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                strings.t('hypothesesNotConclusions'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < hypotheses.length; i++)
                Builder(
                  builder: (context) {
                    final h = hypotheses[i]['data'] as Map;
                    final status = h['status'];
                    final rejected =
                        status == 'contradicted' || status == 'discarded';
                    final supported = status == 'supported_by_test';
                    return ExpansionTile(
                      key: PageStorageKey(
                        'hypothesis-${session['id']}-${session['analysis_steps']}-$i',
                      ),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(
                        bottom: 14,
                        left: 8,
                        right: 8,
                      ),
                      leading: Icon(
                        rejected
                            ? Icons.remove_circle_outline
                            : supported
                            ? Icons.fact_check_outlined
                            : Icons.help_outline,
                        color: rejected
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : supported
                            ? Theme.of(context).colorScheme.primary
                            : Colors.amber,
                      ),
                      title: Text(localized(h, 'cause')?.toString() ?? ''),
                      subtitle: Text(strings.label(status ?? 'proposed')),
                      expandedAlignment: Alignment.centerLeft,
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(localized(h, 'explanation')?.toString() ?? ''),
                        if (technicalDetails) ...[
                          const SizedBox(height: 8),
                          Text(
                            strings.t('references', {
                              'ids': (h['evidence_ids'] as List? ?? []).join(
                                ', ',
                              ),
                            }),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    );
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }
}
