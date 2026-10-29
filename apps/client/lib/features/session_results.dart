import 'package:flutter/material.dart';
import '../core/measurement_points.dart';
import '../l10n/app_strings.dart';

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
                    'value': latest['unit'] == 'boolean'
                        ? strings.booleanValue(latest['value'])
                        : strings.number(latest['value'] as num),
                    'source': strings.label(latest['source']),
                  },
                ),
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
