import 'package:flutter/material.dart';
import '../core/measurement_points.dart';
import '../l10n/app_strings.dart';

/// A received value is distinct from a saved or physically verified reading.
class ObservationReadout extends StatelessWidget {
  final String title;
  final Map observation;
  final Map point;
  final bool live;
  final DateTime? now;
  const ObservationReadout({
    super.key, required this.title, required this.observation,
    this.point = const {}, this.live = false, this.now,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final theme = Theme.of(context);
    final invalid = observation['invalid'] == true;
    final received = observation['received_at'];
    final age = received is num && received.isFinite
        ? (now ?? DateTime.now()).millisecondsSinceEpoch / 1000 - received
        : null;
    final fresh = age != null && age >= 0 && age <= 10;
    final unit = observation['unit'] ?? 'V';
    final matches = invalid || (live && !fresh) ? null
        : observationMatchesCriterion(point, observation['value'], unit);
    final status = invalid ? 'serialInvalidValue'
        : live && !fresh ? 'observationStale'
        : matches == true ? 'observationWithinCriterion'
        : matches == false ? 'observationOutsideCriterion'
        : live && point.isNotEmpty ? 'observationUnitMismatch'
        : live ? 'observationNotLinked' : 'observationSaved';
    final color = invalid || matches == false ? theme.colorScheme.error
        : matches == true ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    final measured = observation['measured_at'];
    final measuredAt = measured is num && measured.isFinite && measured.abs() <= 8640000000000
        ? DateTime.fromMillisecondsSinceEpoch((measured * 1000).round()).toLocal() : null;
    final formats = MaterialLocalizations.of(context);
    final details = <String>[
      if (live) strings.t('observationBoardReported')
      else strings.label(observation['source'] ?? 'manual'),
      if (!live && measuredAt != null)
        '${formats.formatShortDate(measuredAt)} · ${formats.formatTimeOfDay(TimeOfDay.fromDateTime(measuredAt))}',
      if (live && age != null && age >= 0)
        strings.t('observationAge', {'seconds': age.floor()}),
      if (live && observation['sensor'] != null) '${observation['sensor']}',
      if (live && observation['board'] != null) '${observation['board']}',
      if (live) '${observation['channel']}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(
          invalid ? strings.t('observationUnavailable')
              : strings.pointObservation(
                  live && point.isEmpty ? {'kind': 'reported_state'} : point,
                  observation['value'], unit),
          // EditableText scroll offsets must not reuse the parent expansion flag.
          key: PageStorageKey('observation-value-$live-'
              '${observation['channel'] ?? observation['point_id']}-${point['id'] ?? ''}'),
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(strings.t(status), style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        if (point.isNotEmpty && matches != null)
          Text(strings.t('observationExpectedCriterion', {'criterion': strings.criterion(point)})),
        Text(details.join(' · '), style: theme.textTheme.bodySmall),
      ]),
    );
  }
}
