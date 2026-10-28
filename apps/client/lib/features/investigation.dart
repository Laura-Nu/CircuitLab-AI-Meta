import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';

class InvestigationPanels extends StatelessWidget {
  final Map<String, dynamic> session;
  final bool busy;
  final bool technicalDetails;
  final VoidCallback onGenerate;
  const InvestigationPanels({
    super.key,
    required this.session,
    required this.busy,
    this.technicalDetails = false,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final language = Localizations.localeOf(context).languageCode;
    String text(dynamic value) => value is Map
        ? (value[language] ?? value['en'] ?? '').toString()
        : (value ?? '').toString();
    final trace = (session['agent_trace'] as List?) ?? [];
    final stories = (session['storyboards'] as List?) ?? [];
    final latest = stories.isEmpty ? null : stories.first as Map;
    final data = latest?['data'] as Map?;
    final generating = ['pending', 'running'].contains(latest?['status']);
    final terminal = ['resolved', 'inconclusive'].contains(session['state']);
    final canGenerate =
        session['can_edit'] == true &&
        session['storyboard_available'] == true &&
        terminal &&
        (session['analysis_steps'] as num? ?? 0) > 0;
    final frames = data?['frames'] as List? ?? [];
    final facts = <String, Map>{
      for (final fact in data?['facts'] as List? ?? []) fact['id']: fact as Map,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (trace.isNotEmpty) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.t('agentDecisionTrace'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(strings.t('agentTraceDescription')),
                  for (var index = 0; index < trace.length; index++)
                    Builder(
                      builder: (context) {
                        final run = trace[index] as Map;
                        final output = run['output'] as Map? ?? {};
                        final hypotheses = output['hypotheses'] as List? ?? [];
                        final translations =
                            (output['translations'] as Map?)?[language] as Map?;
                        return ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            technicalDetails
                                ? '${index + 1}. ${run['model'] ?? strings.t('analysisErrorTitle')}'
                                : strings.t('diagnosticStepNumber', {
                                    'step': index + 1,
                                  }),
                          ),
                          subtitle: Text(
                            technicalDetails
                                ? '${run['provider'] ?? ''} · ${output['point_id'] ?? output['action'] ?? run['error'] ?? ''}'
                                : output['point_id'] != null
                                ? '${strings.t('point')}: ${output['point_id']}'
                                : strings.t('agentTraceDescription'),
                          ),
                          childrenPadding: const EdgeInsets.only(bottom: 16),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              translations?['rationale'] ??
                                  output['rationale'] ??
                                  '',
                            ),
                            for (final prediction
                                in output['test_predictions'] as List? ??
                                    []) ...[
                              const SizedBox(height: 12),
                              Builder(
                                builder: (context) {
                                  final i =
                                      prediction['hypothesis_index'] as int;
                                  final causes =
                                      translations?['causes'] as List?;
                                  final cause =
                                      causes != null && i < causes.length
                                      ? causes[i]
                                      : i < hypotheses.length
                                      ? hypotheses[i]['cause']
                                      : '';
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.alt_route),
                                    title: Text(cause),
                                    subtitle: Text(
                                      text(prediction['expected_outcome']),
                                    ),
                                  );
                                },
                              ),
                            ],
                            if (technicalDetails &&
                                run['response_model'] != null)
                              Text(
                                '${strings.t('reportedModel')}: ${run['response_model']}',
                              ),
                            if (technicalDetails && run['request_id'] != null)
                              SelectableText(
                                '${strings.t('providerRequest')}: ${run['request_id']}',
                              ),
                            if (technicalDetails &&
                                run['provider'] != 'simulation')
                              Text(
                                strings.t('providerIdentityNotice'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (technicalDetails ||
            session['storyboard_available'] == true ||
            latest != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Circuit Story',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (canGenerate &&
                          (data == null || latest?['stale'] == true))
                        FilledButton.icon(
                          onPressed: busy || generating ? null : onGenerate,
                          icon: const Icon(Icons.auto_stories_outlined),
                          label: Text(
                            strings.t(
                              latest?['status'] == 'failed'
                                  ? 'retryStory'
                                  : 'createStory',
                            ),
                          ),
                        ),
                      if (data != null && technicalDetails)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text: const JsonEncoder.withIndent(
                                  '  ',
                                ).convert(data),
                              ),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(strings.t('storyCopied')),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_outlined),
                          label: Text(strings.t('copyStory')),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    strings.t(
                      session['storyboard_mode'] == 'simulation'
                          ? 'storyPreviewDescription'
                          : technicalDetails
                          ? 'storyDescription'
                          : 'storyDescriptionMember',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!terminal)
                    Text(strings.t('storyNeedsCompletedDiagnosis')),
                  if (terminal && !canGenerate && data == null)
                    Text(strings.t('storyUnavailable')),
                  if (generating) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(strings.t('storyGenerating')),
                  ],
                  if (latest?['status'] == 'failed')
                    Text(strings.t('storyFailed')),
                  if (data != null) ...[
                    if (latest?['stale'] == true) Text(strings.t('storyStale')),
                    if (data['simulation'] == true ||
                        data['diagnosis_mode'] == 'simulation')
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.amber.shade700),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.science_outlined),
                            const SizedBox(width: 10),
                            Expanded(child: Text(strings.t('storySimulation'))),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      text(data['title']),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      text(data['notice']),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth >= 720
                            ? (constraints.maxWidth - 16) / 2
                            : constraints.maxWidth;
                        return Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            for (var i = 0; i < frames.length; i++)
                              SizedBox(
                                width: width,
                                child: Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: .35),
                                    ),
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: .045),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        child: Text('${i + 1}'),
                                      ),
                                      const SizedBox(height: 14),
                                      Text(
                                        text(frames[i]['headline']),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(text(frames[i]['caption'])),
                                      const SizedBox(height: 12),
                                      for (final id in frames[i]['source_ids'])
                                        if (facts[id] != null)
                                          _RecordedFact(fact: facts[id]!),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    if (technicalDetails) ...[
                      const SizedBox(height: 14),
                      Text(
                        '${data['audit']?['provider']} · ${data['audit']?['model']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      SelectableText(
                        '${strings.t('sourceFingerprint')}: ${data['source_sha256']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RecordedFact extends StatelessWidget {
  final Map fact;
  const _RecordedFact({required this.fact});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final data = fact['data'] as Map;
    final kind = fact['kind'];
    final language = Localizations.localeOf(context).languageCode;
    final lines = <String>[];
    switch (kind) {
      case 'measurement':
        lines.add(
          '${data['point_id']}: ${(data['value'] as num).toStringAsFixed(3)} V · ${strings.label(data['source'])}',
        );
        if (data['calibration_id'] != null) {
          lines.add(
            '${strings.t('calibrationIdentifier')}: ${data['calibration_id']}',
          );
        }
      case 'verification':
        final check = data['data'] as Map;
        lines.add(
          strings
              .t(
                check['passed'] == true
                    ? 'theElectricalCriteriaAreMet'
                    : 'theFunctionalCriterionIsNotMet',
              )
              .replaceFirst('✓ ', ''),
        );
        if (check['physical_verification'] != true) {
          lines.add(strings.t('thisDoesNotEstablishFullPhysicalVerification'));
        }
        for (final point in check['checks'] as List? ?? []) {
          lines.add(
            '${point['point_id']}: ${point['value']} V / ${point['min_v']}–${point['max_v']} V',
          );
        }
      case 'intervention':
        lines.add(data['description'].toString());
      case 'specification':
        lines.add(data['expected'].toString());
        for (final point in data['specification']['points'] as List? ?? []) {
          lines.add('${point['id']}: ${point['min_v']}–${point['max_v']} V');
        }
      case 'decision':
        final output = data['output'] as Map;
        lines.add(
          (output['translations']?[language]?['rationale'] ??
                  output['rationale'] ??
                  '')
              .toString(),
        );
      case 'failure':
        lines.add(strings.label(data['status'] ?? 'timeout'));
      default:
        lines.add(strings.t('imageAttached'));
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      title: Text(strings.t('storySource_$kind')),
      subtitle: kind == 'measurement' ? Text(lines.first) : null,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(line)),
        SelectableText(
          fact['id'].toString(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
