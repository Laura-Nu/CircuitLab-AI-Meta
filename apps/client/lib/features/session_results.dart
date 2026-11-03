import 'package:flutter/material.dart';
import '../core/measurement_points.dart';
import '../l10n/app_strings.dart';
import 'observation_readout.dart';

/// Uses persisted session facts; an open USB port alone is not a measurement.
class SessionResults extends StatelessWidget {
  final Map session;
  final List<dynamic> events;
  final bool busy;
  final VoidCallback onReport;
  const SessionResults({
    super.key,
    required this.session,
    required this.events,
    required this.busy,
    required this.onReport,
  });
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final readings = List<dynamic>.of(session['measurements'] as List? ?? []);
    final requests = events
        .where((e) => e['kind'] == 'hardware_requested')
        .toList();
    final request = requests.isEmpty ? null : requests.last;
    final replies = request == null
        ? []
        : events
              .where(
                (e) =>
                    [
                      'hardware_result',
                      'hardware_failed',
                    ].contains(e['kind']) &&
                    e['data']['command_id'] == request['data']['command_id'],
              )
              .toList();
    final reply = replies.isEmpty ? null : replies.last;
    final waiting = request != null && reply == null;
    final failed = reply != null && reply['data']['status'] != 'ok';
    final specification = session['specification'] as Map? ?? {};
    final latest = readings.isEmpty
        ? null
        : readings.reduce(
            (a, b) =>
                (a['measured_at'] as num? ?? 0) >
                    (b['measured_at'] as num? ?? 0)
                ? a
                : b,
          );
    final latestByPoint = <String, Map>{};
    for (final reading in readings.cast<Map>()) {
      final id = '${reading['point_id']}';
      if (!latestByPoint.containsKey(id) ||
          (reading['measured_at'] as num? ?? 0) >=
              (latestByPoint[id]!['measured_at'] as num? ?? 0)) {
        latestByPoint[id] = reading;
      }
    }
    return Card(
      key: const ValueKey('sessionResults'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.t('sessionResultsTitle'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(strings.t('sessionReadingsCount', {'count': readings.length})),
            if ((session['context_evidence'] as List? ?? []).isNotEmpty) ExpansionTile(
              key: PageStorageKey('context-evidence-${session['id']}'),
              tilePadding: EdgeInsets.zero,
              title: Text(strings.t('contextEvidenceTitle')),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final evidence in session['context_evidence'] as List) Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(strings.t(evidence['kind'] == 'program_submitted'
                      ? 'programSubmittedEvent' : 'problemReportedEvent')),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      key: PageStorageKey('context-scroll-${evidence['id']}'), primary: false,
                      child: SelectableText('${evidence['data']['content']}',
                        key: PageStorageKey('context-text-${evidence['id']}')),
                    ),
                  ),
                ]),
              )],
            ),
            if ((session['serial_captures'] as List? ?? []).isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(strings.t('serialSavedCaptures', {
                'count': (session['serial_captures'] as List).length,
              })),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(strings.t('serialLatestCapture')),
                children: [ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(child: SelectableText(
                    ((session['serial_captures'] as List).first['data']['lines'] as List).join('\n'),
                  )),
                )],
              ),
            ],
            if (latest != null) ...[
              const SizedBox(height: 8),
              Text(
                strings.t(
                  latest['unit'] == 'boolean'
                      ? 'latestRecordedBoolean'
                      : 'latestRecordedReading',
                  {
                    'point': measurementPointName(
                      specification,
                      latest['point_id'],
                    ),
                    'value': strings.pointObservation(
                      measurementPoint(specification, latest['point_id']),
                      latest['value'], latest['unit'] ?? 'V'),
                    'source': strings.label(latest['source']),
                  },
                ),
              ),
              ExpansionTile(
                key: PageStorageKey('saved-observations-${session['id']}'),
                tilePadding: EdgeInsets.zero,
                title: Text(strings.t('observationSavedByPoint')),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final reading in latestByPoint.values)
                  ObservationReadout(
                    title: measurementPointName(specification, reading['point_id']),
                    observation: reading,
                    point: measurementPoint(specification, reading['point_id']),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(strings.t('usbNoReadingYet')),
            ],
            if (waiting || reply != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (waiting)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        failed
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 19,
                        color: failed
                            ? Colors.amber
                            : Theme.of(context).colorScheme.primary,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        waiting
                            ? strings.t('hardwareWaitingForResult')
                            : failed
                            ? strings.t('hardwareReadFailed', {
                                'reason': strings.label(
                                  reply['data']['status'] ?? 'timeout',
                                ),
                              })
                            : strings.t('hardwareReadSaved'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('viewSessionReport'),
              onPressed: busy ? null : onReport,
              icon: const Icon(Icons.article_outlined, size: 18),
              label: Text(strings.t('viewSessionReport')),
            ),
            const SizedBox(height: 8),
            Text(
              strings.t('sessionReportSnapshotHelp'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
