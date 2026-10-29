import 'package:flutter/material.dart';
import '../core/form_fields.dart';
import '../core/measurement_points.dart';
import '../l10n/app_strings.dart';

/// A requested diagnostic point cannot be exchanged for a different measurement.
class HardwarePointField extends StatelessWidget {
  final Map specification;
  final List<dynamic> points;
  final String value;
  final bool locked;
  final ValueChanged<String> onChanged;
  const HardwarePointField({
    super.key,
    required this.specification,
    required this.points,
    required this.value,
    required this.locked,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final pin = const {'TP1': 'A0', 'TP2': 'A1', 'TP3': 'A2'}[value];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (locked)
          InputDecorator(
            decoration: InputDecoration(
              label: RequiredLabel(strings.t('point')),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(measurementPointName(specification, value)),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.lock_outline, size: 18),
              ],
            ),
          )
        else
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: value,
            isDense: false,
            decoration: InputDecoration(
              label: RequiredLabel(strings.t('point')),
            ),
            items: [
              for (final p in points)
                DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text(
                    measurementPointName(specification, p['id']),
                    maxLines: 2,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        if (locked) ...[
          const SizedBox(height: 8),
          Text(
            strings.t('requestedHardwarePointHelp'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (booleanPoint(specification, value)) ...[
          const SizedBox(height: 8),
          Text(
            strings.t('booleanUsbHelp'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (pin != null) ...[
          const SizedBox(height: 8),
          Text(
            strings.t('instrumentChannelHint', {
              'point': measurementPointName(
                specification,
                value,
                includeReference: true,
              ),
              'pin': pin,
            }),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
