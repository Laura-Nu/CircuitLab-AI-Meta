import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

class SpecificationDialog extends StatefulWidget {
  final Map<String, dynamic> specification;
  final double supplyVoltage;
  const SpecificationDialog({
    super.key,
    required this.specification,
    required this.supplyVoltage,
  });
  @override
  State<SpecificationDialog> createState() => _SpecificationDialogState();
}

class _PointFields {
  final String id;
  final TextEditingController label;
  final TextEditingController minimum;
  final TextEditingController maximum;
  _PointFields(Map<String, dynamic> point)
    : id = point['id'] as String,
      label = TextEditingController(text: point['label']?.toString() ?? ''),
      minimum = TextEditingController(text: point['min_v']?.toString() ?? ''),
      maximum = TextEditingController(text: point['max_v']?.toString() ?? '');
  void dispose() {
    label.dispose();
    minimum.dispose();
    maximum.dispose();
  }
}

class _SpecificationDialogState extends State<SpecificationDialog> {
  static const maximumPoints = 8;
  final formKey = GlobalKey<FormState>();
  late final connections = TextEditingController(
    text: (widget.specification['connections'] as List?)?.join('\n') ?? '',
  );
  late final description = TextEditingController(
    text: widget.specification['functional_description'] ?? '',
  );
  late final List<_PointFields> points = [
    for (final point in (widget.specification['points'] as List? ?? []))
      _PointFields(Map<String, dynamic>.from(point)),
  ];
  // Dispose removed controllers only after their fields have unmounted.
  final removedPoints = <_PointFields>[];
  String? pointError;

  @override
  void initState() {
    super.initState();
    if (points.isEmpty) points.add(_PointFields({'id': 'TP1'}));
  }

  @override
  void dispose() {
    connections.dispose();
    description.dispose();
    for (final point in [...points, ...removedPoints]) {
      point.dispose();
    }
    super.dispose();
  }

  String tr(String key, [Map<String, String>? values]) =>
      AppStrings.of(context).t(key, values ?? const {});
  double? voltage(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));
  bool unused(_PointFields point) =>
      point.label.text.trim().isEmpty &&
      point.minimum.text.trim().isEmpty &&
      point.maximum.text.trim().isEmpty;

  void addPoint() {
    final used = points.map((p) => p.id).toSet();
    final id = List.generate(
      99,
      (index) => 'TP${index + 1}',
    ).firstWhere((id) => !used.contains(id));
    setState(() {
      points.add(_PointFields({'id': id}));
      pointError = null;
    });
  }

  Widget voltageField(_PointFields point, {required bool minimum}) =>
      TextFormField(
        key: ValueKey(point.id + (minimum ? '-min' : '-max')),
        controller: minimum ? point.minimum : point.maximum,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: tr(minimum ? 'minV' : 'maxV')),
        validator: (text) {
          if (unused(point)) return null;
          final value = voltage(text ?? '');
          if (value == null ||
              !value.isFinite ||
              value < 0 ||
              value > widget.supplyVoltage) {
            return tr('testPointVoltageInvalid', {
              'max': widget.supplyVoltage.toString(),
            });
          }
          final low = voltage(point.minimum.text);
          final high = voltage(point.maximum.text);
          if (low != null && high != null && low > high) {
            return tr('testPointRangeInvalid');
          }
          return null;
        },
      );

  Widget pointFields(_PointFields point) => Padding(
    key: ValueKey(point.id),
    padding: const EdgeInsets.only(bottom: 16),
    child: LayoutBuilder(
      builder: (_, constraints) {
        final label = TextFormField(
          key: ValueKey('${point.id}-label'),
          controller: point.label,
          maxLength: 120,
          decoration: InputDecoration(labelText: tr('label'), counterText: ''),
          validator: (value) => !unused(point) && (value ?? '').trim().isEmpty
              ? tr('testPointLabelRequired')
              : null,
        );
        final remove = IconButton(
          tooltip: tr('removeTestPoint', {'point': point.id}),
          onPressed: points.length <= 1
              ? null
              : () => setState(() {
                  points.remove(point);
                  removedPoints.add(point);
                }),
          icon: const Icon(Icons.remove_circle_outline),
        );
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(point.id)),
                  remove,
                ],
              ),
              label,
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: voltageField(point, minimum: true)),
                  const SizedBox(width: 10),
                  Expanded(child: voltageField(point, minimum: false)),
                ],
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 17),
              child: Text(point.id),
            ),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: label),
            const SizedBox(width: 8),
            Expanded(child: voltageField(point, minimum: true)),
            const SizedBox(width: 8),
            Expanded(child: voltageField(point, minimum: false)),
            remove,
          ],
        );
      },
    ),
  );

  void submit() {
    if (!formKey.currentState!.validate()) return;
    final defined = points.where((point) => !unused(point)).toList();
    if (defined.isEmpty) {
      setState(() => pointError = tr('atLeastOneTestPoint'));
      return;
    }
    Navigator.pop(context, {
      'connections': connections.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(),
      'functional_description': description.text.trim(),
      'points': [
        for (final point in defined)
          {
            'id': point.id,
            'label': point.label.text.trim(),
            'min_v': voltage(point.minimum.text),
            'max_v': voltage(point.maximum.text),
          },
      ],
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('schematicAndInitialCriteria')),
    content: SizedBox(
      width: 650,
      child: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('physicallyConfirmTheConnectionsDefineTheRangesThat')),
              const SizedBox(height: 18),
              TextFormField(
                controller: connections,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: tr('confirmedConnectionsOnePerLine'),
                ),
                validator: (value) {
                  final lines = (value ?? '')
                      .split('\n')
                      .where((line) => line.trim().isNotEmpty);
                  return lines.isEmpty || lines.length > 50
                      ? tr('connectionsRequired')
                      : null;
                },
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: description,
                minLines: 2,
                maxLines: 5,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: tr('functionalTestCondition'),
                ),
                validator: (value) => (value ?? '').trim().length < 5
                    ? tr('functionalDescriptionRequired')
                    : null,
              ),
              const SizedBox(height: 18),
              for (final point in points) pointFields(point),
              OutlinedButton.icon(
                key: const ValueKey('add-test-point'),
                onPressed: points.length < maximumPoints ? addPoint : null,
                icon: const Icon(Icons.add),
                label: Text(tr('addTestPoint')),
              ),
              const SizedBox(height: 12),
              Text(tr('testPointLimit', {'count': '$maximumPoints'})),
              const SizedBox(height: 8),
              Text(tr('leaveUnusedPointsEmptyAllDefinedPointsWill')),
              if (pointError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    pointError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('cancel')),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(tr('iConfirmTheSchematicAndCriteria')),
      ),
    ],
  );
}
