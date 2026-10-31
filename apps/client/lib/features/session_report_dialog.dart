import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/form_fields.dart';
import '../core/measurement_points.dart';
import '../l10n/app_strings.dart';
import 'diagnostic_summary.dart';
import 'session_guidance.dart';

/// A readable snapshot; copying uses the export produced from the same snapshot.
class SessionReportDialog extends StatefulWidget {
  final Map<String, dynamic> report;
  final bool technicalDetails;
  const SessionReportDialog({
    super.key,
    required this.report,
    this.technicalDetails = false,
  });

  @override
  State<SessionReportDialog> createState() => _SessionReportDialogState();
}

class _SessionReportDialogState extends State<SessionReportDialog> {
  final scroll = ScrollController(keepScrollOffset: false);
  String? copied, copyError;
  AppStrings get strings => AppStrings.of(context);
  Map<String, dynamic> get report => widget.report;
  List<dynamic> items(String name) => report[name] as List? ?? [];

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> copy(bool json) async {
    try {
      final data = Map<String, dynamic>.of(report)..remove('markdown');
      final content = json
          ? const JsonEncoder.withIndent('  ').convert(data)
          : report['markdown'] as String;
      await Clipboard.setData(ClipboardData(text: content));
      if (mounted) {
        setState(() {
          copied = json ? 'json' : 'text';
          copyError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          copyError = strings.t('reportClipboardFailed');
        });
      }
    }
  }

  String localized(Map data, String field) =>
      ((data['translations'] as Map?)?[strings.language]?[field] ??
              data[field] ??
              '')
          .toString();

  String date(dynamic epoch) {
    final value = epoch is num
        ? DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round()).toLocal()
        : DateTime.tryParse(epoch?.toString() ?? '')?.toLocal();
    if (value == null) return '';
    final locale = MaterialLocalizations.of(context);
    return '${locale.formatCompactDate(value)} · ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
  }

  Widget note(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      Text(value, style: const TextStyle(height: 1.5)),
    ],
  );

  Widget panel(
    String title,
    IconData icon,
    Widget child, {
    int? count,
    bool? expanded,
  }) {
    final heading = Text(title, style: Theme.of(context).textTheme.titleMedium);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: expanded != null
          ? ExpansionTile(
              key: PageStorageKey('report-${report['id']}-$title'),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 6,
              ),
              leading: Icon(icon, size: 22),
              title: heading,
              subtitle: count == null
                  ? null
                  : Text(
                      strings.t(count == 1 ? 'reportCountOne' : 'reportCount', {
                        'count': count,
                      }),
                    ),
              initiallyExpanded: expanded,
              expandedAlignment: Alignment.centerLeft,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              children: [child],
            )
          : Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 22),
                      const SizedBox(width: 10),
                      Expanded(child: heading),
                    ],
                  ),
                  const SizedBox(height: 16),
                  child,
                ],
              ),
            ),
    );
  }

  Widget stack(Iterable<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final child in children)
        Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
    ],
  );

  Widget tag(String text, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: (color ?? Theme.of(context).colorScheme.primary).withValues(
        alpha: .09,
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = report['state'];
    final tone = sessionTone(state);
    final spec = report['specification'] as Map? ?? {};
    final readings = items('measurements');
    final evidence = items('evidence');
    final verifications = items('verifications');
    final events = items('events');
    final presentation = report['presentation'] as Map? ?? {};
    final eventLabels = <dynamic, dynamic>{
      for (final item in presentation['events'] as List? ?? [])
        item['sequence']: item['label'],
    };
    final provenance = <dynamic, Map>{
      for (final event in events.where(
        (e) => e['kind'] == 'serial_reading_received',
      ))
        event['data']['measurement_id']: event['data'] as Map,
    };
    final oldHypotheses = items('hypotheses')
        .where((h) => h['data']['analysis_step'] != report['analysis_steps'])
        .toList();
    final captures = events
        .where((e) => e['kind'] == 'serial_captured')
        .toList();
    return Dialog(
      key: const ValueKey('session-report-dialog'),
      insetPadding: formDialogInsets(context),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 1040,
        height: math.min(900, MediaQuery.sizeOf(context).height - 48),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      strings.t('sessionReport'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('close-report-icon'),
                    tooltip: strings.t('close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            Expanded(
              child: Scrollbar(
                controller: scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  key: const ValueKey('report-body-scroll'),
                  controller: scroll,
                  padding: const EdgeInsets.all(20),
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: tone.withValues(alpha: .07),
                            border: Border.all(
                              color: tone.withValues(alpha: .3),
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                report['title']?.toString() ?? '',
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  tag(
                                    presentation['state'] ??
                                        strings.label(state?.toString() ?? ''),
                                    color: tone,
                                  ),
                                  if (report['diagnosis_mode'] == 'simulation')
                                    tag(
                                      strings.t('reportSimulation'),
                                      color: Colors.amber,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Text(
                                strings.t('sessionReportSnapshotHelp'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  tag(
                                    strings.t(
                                      readings.length == 1
                                          ? 'reportReadingCountOne'
                                          : 'reportReadingCount',
                                      {'count': readings.length},
                                    ),
                                  ),
                                  tag(
                                    strings.t(
                                      evidence.length == 1
                                          ? 'reportEvidenceCountOne'
                                          : 'reportEvidenceCount',
                                      {'count': evidence.length},
                                    ),
                                  ),
                                  tag(
                                    strings.t(
                                      report['analysis_steps'] == 1
                                          ? 'reportStepCountOne'
                                          : 'reportStepCount',
                                      {'count': report['analysis_steps'] ?? 0},
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        panel(
                          strings.t('reportOverview'),
                          Icons.dashboard_outlined,
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final twoColumns = constraints.maxWidth >= 600;
                              final width = twoColumns
                                  ? (constraints.maxWidth - 24) / 2
                                  : constraints.maxWidth;
                              return Wrap(
                                spacing: 24,
                                runSpacing: 18,
                                children: [
                                  SizedBox(
                                    width: width,
                                    child: note(
                                      strings.t('reportFamily'),
                                      presentation['family'] ??
                                          strings.label(report['family'] ?? ''),
                                    ),
                                  ),
                                  SizedBox(
                                    width: width,
                                    child: note(
                                      strings.t('reportPurpose'),
                                      strings.t(
                                        report['purpose'] == 'check_operation'
                                            ? 'purposeCheckOperation'
                                            : 'purposeDiagnosis',
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: width,
                                    child: note(
                                      strings.t('reportSupply'),
                                      strings.observation(report['supply_v']),
                                    ),
                                  ),
                                  if ((report['setup'] ?? '')
                                      .toString()
                                      .trim()
                                      .isNotEmpty)
                                    SizedBox(
                                      width: width,
                                      child: note(
                                        strings.t('reportBoard'),
                                        report['setup'].toString(),
                                      ),
                                    ),
                                  SizedBox(
                                    width: constraints.maxWidth,
                                    child: note(
                                      strings.t('reportExpected'),
                                      report['expected']?.toString() ?? '',
                                    ),
                                  ),
                                  SizedBox(
                                    width: constraints.maxWidth,
                                    child: note(
                                      strings.t('reportSymptoms'),
                                      (report['symptoms'] ?? '')
                                              .toString()
                                              .trim()
                                              .isEmpty
                                          ? strings.t('noSymptomsReported')
                                          : report['symptoms'].toString(),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        if ((report['pending_test'] as Map?)?.isNotEmpty ==
                                true ||
                            items('hypotheses').isNotEmpty) ...[
                          DiagnosticSummary(
                            session: report,
                            technicalDetails: widget.technicalDetails,
                          ),
                          const SizedBox(height: 16),
                        ],
                        panel(
                          strings.t('reportReadings'),
                          Icons.monitor_heart_outlined,
                          readings.isEmpty
                              ? Text(strings.t('reportReadingsEmpty'))
                              : stack(
                                  readings.reversed.map(
                                    (reading) => Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: .035),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: Theme.of(context).dividerColor,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            measurementPointName(
                                              spec,
                                              reading['point_id'],
                                              includeReference:
                                                  widget.technicalDetails,
                                            ),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            spacing: 16,
                                            runSpacing: 8,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              Text(
                                                strings.observation(
                                                  reading['value'],
                                                  reading['unit'] ?? 'V',
                                                ),
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleLarge,
                                              ),
                                              tag(
                                                strings.label(
                                                  reading['source'] ?? '',
                                                ),
                                              ),
                                              Text(
                                                strings.t(
                                                  reading['phase'] ==
                                                          'verification'
                                                      ? 'afterIntervention'
                                                      : 'reportDiagnosisPhase',
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            date(reading['measured_at']),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                          if (reading['source'] ==
                                                  'serial_reported' &&
                                              provenance[reading['id']] !=
                                                  null) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              strings.t('reportFirmwareSource', {
                                                'source': [
                                                  for (final field in [
                                                    'channel',
                                                    'sensor',
                                                    'board',
                                                    'label',
                                                  ])
                                                    if (provenance[reading['id']]![field] !=
                                                        null)
                                                      provenance[reading['id']]![field],
                                                ].join(' · '),
                                              }),
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        panel(
                          strings.t('reportVerification'),
                          Icons.fact_check_outlined,
                          verifications.isEmpty
                              ? Text(strings.t('reportVerificationEmpty'))
                              : stack(
                                  verifications.map((item) {
                                    final data = item['data'] as Map;
                                    final functional =
                                        data['functional_check'] as Map?;
                                    final physical =
                                        data['physical_verification'] == true &&
                                        data['passed'] == true &&
                                        functional?['passed'] == true;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            tag(
                                              strings.t(
                                                data['passed'] == true
                                                    ? 'functionalTestPassed'
                                                    : 'functionalTestFailed',
                                              ),
                                              color: data['passed'] == true
                                                  ? const Color(0xFF6CE5BC)
                                                  : Colors.amber,
                                            ),
                                            Text(
                                              date(item['created_at']),
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          strings.t(
                                            physical
                                                ? 'reportPhysicalVerified'
                                                : 'thisDoesNotEstablishFullPhysicalVerification',
                                          ),
                                        ),
                                        if (data['assessment_kind'] ==
                                            'baseline') ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            strings.t('baselineResultNotice'),
                                          ),
                                        ],
                                        for (final check
                                            in data['checks'] as List? ??
                                                []) ...[
                                          const SizedBox(height: 10),
                                          note(
                                            measurementPointName(
                                              spec,
                                              check['point_id'],
                                            ),
                                            '${strings.observation(check['value'], check['unit'] ?? 'V')} / ${strings.criterion(check)} · ${strings.label(check['source'] ?? '')}',
                                          ),
                                        ],
                                        if (functional != null) ...[
                                          const SizedBox(height: 12),
                                          note(
                                            strings.t(
                                              'reportFunctionalCondition',
                                            ),
                                            functional['criteria']
                                                    ?.toString() ??
                                                '',
                                          ),
                                          const SizedBox(height: 10),
                                          note(
                                            strings.t(
                                              'functionalTestObservations',
                                            ),
                                            functional['observations']
                                                    ?.toString() ??
                                                '',
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            strings.t(
                                              functional['passed'] == true
                                                  ? 'functionalTestPassed'
                                                  : 'functionalTestFailed',
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  }),
                                ),
                        ),
                        panel(
                          strings.t('reportCriteria'),
                          Icons.schema_outlined,
                          stack([
                            if ((spec['functional_description'] ?? '')
                                .toString()
                                .isNotEmpty)
                              note(
                                strings.t('reportFunctionalCondition'),
                                spec['functional_description'].toString(),
                              ),
                            for (final connection
                                in spec['connections'] as List? ?? [])
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.subdirectory_arrow_right,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(connection.toString())),
                                ],
                              ),
                            for (final point in spec['points'] as List? ?? [])
                              note(
                                measurementPointName(
                                  spec,
                                  point['id'],
                                  includeReference: widget.technicalDetails,
                                ),
                                strings.criterion(point),
                              ),
                          ]),
                          expanded: false,
                          count: (spec['points'] as List? ?? []).length,
                        ),
                        if (evidence.isNotEmpty ||
                            items('removed_evidence').isNotEmpty)
                          panel(
                            strings.t('reportEvidence'),
                            Icons.photo_library_outlined,
                            stack([
                              for (final item in evidence)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.image_outlined),
                                  title: Text(
                                    item['mime']?.toString() ?? 'Image',
                                  ),
                                  subtitle: widget.technicalDetails
                                      ? Text(
                                          '${item['id']}\nSHA-256: ${item['sha256']}',
                                        )
                                      : null,
                                ),
                              for (final item in items('removed_evidence'))
                                note(
                                  strings.t('reportWithdrawnEvidence'),
                                  widget.technicalDetails
                                      ? item['id'].toString()
                                      : item['mime']?.toString() ?? 'Image',
                                ),
                              if (report['evidence_review_required'] == true)
                                Text(strings.t('evidenceReviewRequired')),
                            ]),
                            expanded: false,
                            count: evidence.length,
                          ),
                        if (items('interventions').isNotEmpty)
                          panel(
                            strings.t('reportInterventions'),
                            Icons.build_outlined,
                            stack(
                              items('interventions').map(
                                (item) => note(
                                  date(item['created_at']),
                                  item['description'],
                                ),
                              ),
                            ),
                            expanded: false,
                            count: items('interventions').length,
                          ),
                        if (oldHypotheses.isNotEmpty)
                          panel(
                            strings.t('reportHistory'),
                            Icons.history,
                            stack(
                              oldHypotheses.map(
                                (item) => note(
                                  localized(item['data'], 'cause'),
                                  localized(item['data'], 'explanation'),
                                ),
                              ),
                            ),
                            expanded: false,
                            count: oldHypotheses.length,
                          ),
                        if (captures.isNotEmpty)
                          panel(
                            strings.t('serialLatestCapture'),
                            Icons.terminal,
                            stack(
                              captures.map(
                                (event) => note(
                                  date(event['created_at']),
                                  (event['data']['lines'] as List? ?? []).join(
                                    '\n',
                                  ),
                                ),
                              ),
                            ),
                            expanded: false,
                            count: captures.length,
                          ),
                        panel(
                          strings.t('timeline'),
                          Icons.timeline_outlined,
                          stack(
                            events.map(
                              (event) => note(
                                eventLabels[event['sequence']]?.toString() ??
                                    strings.label(event['kind']),
                                [
                                      date(event['created_at']),
                                      if (event['kind'] ==
                                          'investigation_closed')
                                        event['data']['reason'] ?? '',
                                      if (event['kind'] ==
                                          'connection_confirmed')
                                        event['data']['description'] ?? '',
                                    ]
                                    .where((v) => v.toString().isNotEmpty)
                                    .join('\n'),
                              ),
                            ),
                          ),
                          expanded: false,
                          count: events.length,
                        ),
                        for (final story in items('storyboards'))
                          if (story['data'] is Map)
                            panel(
                              'Circuit Story',
                              Icons.auto_stories_outlined,
                              stack([
                                if (story['data']['simulation'] == true ||
                                    story['data']['diagnosis_mode'] ==
                                        'simulation')
                                  tag(
                                    strings.t('reportSimulation'),
                                    color: Colors.amber,
                                  ),
                                if (story['stale'] == true)
                                  Text(strings.t('storyStale')),
                                Text(
                                  story['data']['title']?[strings.language]
                                          ?.toString() ??
                                      '',
                                ),
                                Text(
                                  story['data']['notice']?[strings.language]
                                          ?.toString() ??
                                      '',
                                ),
                                for (final frame
                                    in story['data']['frames'] as List? ?? [])
                                  note(
                                    frame['headline']?[strings.language]
                                            ?.toString() ??
                                        '',
                                    frame['caption']?[strings.language]
                                            ?.toString() ??
                                        '',
                                  ),
                              ]),
                              expanded: false,
                            ),
                        panel(
                          strings.t('reportLimits'),
                          Icons.info_outline,
                          stack([
                            Text(
                              presentation['original_content_notice']
                                      ?.toString() ??
                                  strings.t('reportDescription'),
                            ),
                            for (final item in items('limitations'))
                              Text('• $item'),
                          ]),
                          expanded: false,
                        ),
                        if (widget.technicalDetails)
                          panel(
                            strings.t('reportTechnical'),
                            Icons.data_object,
                            stack([
                              note('ID', report['id']?.toString() ?? ''),
                              for (final run in items('model_runs'))
                                note(
                                  (run['data']['model'] ?? '').toString(),
                                  (run['data']['provider'] ?? '').toString(),
                                ),
                            ]),
                            expanded: false,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (copyError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        copyError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      if (widget.technicalDetails)
                        TextButton.icon(
                          key: const ValueKey('copy-report-json'),
                          onPressed: () => copy(true),
                          icon: Icon(
                            copied == 'json' ? Icons.check : Icons.data_object,
                            size: 18,
                          ),
                          label: Text(
                            strings.t(
                              copied == 'json'
                                  ? 'copiedToClipboard'
                                  : 'reportCopyData',
                            ),
                          ),
                        ),
                      if (report['markdown'] is String)
                        OutlinedButton.icon(
                          key: const ValueKey('copy-report-text'),
                          onPressed: () => copy(false),
                          icon: Icon(
                            copied == 'text'
                                ? Icons.check
                                : Icons.copy_outlined,
                            size: 18,
                          ),
                          label: Text(
                            strings.t(
                              copied == 'text'
                                  ? 'copiedToClipboard'
                                  : 'reportCopyText',
                            ),
                          ),
                        ),
                      FilledButton(
                        key: const ValueKey('close-report'),
                        onPressed: () => Navigator.pop(context),
                        child: Text(strings.t('close')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
