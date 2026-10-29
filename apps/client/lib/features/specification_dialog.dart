import '../core/number_format.dart';
import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../core/form_fields.dart';
import '../core/measurement_points.dart';

class SpecificationDialog extends StatefulWidget {
  final Map<String, dynamic> specification;
  final double supplyVoltage;
  final String project;
  const SpecificationDialog({
    super.key,
    required this.specification,
    required this.supplyVoltage,
    this.project = '',
  });
  @override
  State<SpecificationDialog> createState() => _SpecificationDialogState();
}

class _PointFields {
  final String id;
  String kind;
  bool typeSelected;
  bool? expectedState;
  bool get isBoolean => kind == 'digital_state' || kind == 'reported_state';
  bool get isNumber => kind == 'numeric';
  bool get isText => kind == 'text';
  final TextEditingController label;
  final TextEditingController minimum;
  final TextEditingController maximum;
  final TextEditingController unit;
  final TextEditingController expectedText;
  _PointFields(Map<String, dynamic> point)
    : id = point['id'] as String,
      kind = point['value_kind'] == 'boolean'
          ? point['kind'] == 'reported_state' ? 'reported_state' : 'digital_state'
          : point['value_kind'] == 'number' ? 'numeric'
          : point['value_kind'] == 'text' ? 'text'
          : measurementPointKinds.containsKey(point['kind'])
          ? point['kind'] as String
          : 'custom',
      typeSelected = point['value_kind'] != null || point['min_v'] != null || point['max_v'] != null,
      expectedState = point['expected_state'] as bool?,
      label = TextEditingController(text: point['label']?.toString() ?? ''),
      minimum = TextEditingController(
        text: (point['min_value'] ?? point['min_v']) is num
          ? formatNumber((point['min_value'] ?? point['min_v']) as num) : '',
      ),
      maximum = TextEditingController(
        text: (point['max_value'] ?? point['max_v']) is num
          ? formatNumber((point['max_value'] ?? point['max_v']) as num) : '',
      ),
      unit = TextEditingController(text: point['unit'] ?? ''),
      expectedText = TextEditingController(text: point['expected_text'] ?? '');
  void dispose() {
    label.dispose();
    minimum.dispose();
    maximum.dispose();
    unit.dispose();
    expectedText.dispose();
  }
}

class _SpecificationDialogState extends State<SpecificationDialog> {
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
      !point.typeSelected &&
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
        keyboardType: TextInputType.numberWithOptions(decimal: true, signed: point.isNumber),
        decoration: InputDecoration(
          label: RequiredLabel(tr(point.isNumber
            ? (minimum ? 'minimumValue' : 'maximumValue') : (minimum ? 'minV' : 'maxV'))),
          errorMaxLines: 4,
        ),
        validator: (text) {
          if (unused(point)) return null;
          final value = voltage(text ?? '');
          if (value == null ||
              !value.isFinite ||
              (!point.isNumber && (value < 0 || value > widget.supplyVoltage))) {
            return point.isNumber ? tr('validNumberRequired') : tr('testPointVoltageInvalid', {
              'max': AppStrings.of(context).number(widget.supplyVoltage),
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

  Widget rangeFields(_PointFields point) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth / textScale < 360) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            voltageField(point, minimum: true),
            const SizedBox(height: 10),
            voltageField(point, minimum: false),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: voltageField(point, minimum: true)),
          const SizedBox(width: 10),
          Expanded(child: voltageField(point, minimum: false)),
        ],
      );
    },
  );

  Widget pointFields(_PointFields point) => Padding(
    key: ValueKey(point.id),
    padding: const EdgeInsets.only(bottom: 16),
    child: Builder(
      builder: (context) {
        final label = TextFormField(
          key: ValueKey('${point.id}-label'),
          controller: point.label,
          maxLength: 120,
          decoration: InputDecoration(
            label: RequiredLabel(tr('measurementLocation')),
            hintText: tr('measurementLocationHint'),
            hintMaxLines: 2,
            counterText: '',
          ),
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('measurementPointNumber', {
                      'number': point.id.substring(2),
                    }),
                  ),
                ),
                remove,
              ],
            ),
            DropdownButtonFormField<String>(
              itemHeight: null,
              key: ValueKey('${point.id}-kind'),
              initialValue: !point.typeSelected ? null :
                ['supply', 'sensor_signal', 'dc_output'].contains(point.kind) ? 'custom' : point.kind,
              isExpanded: true,
              isDense: false,
              decoration: InputDecoration(
                label: RequiredLabel(tr('measurementConnectionType')),
              ),
              items: [
                for (final kind in ['custom', 'numeric', 'reported_state', 'text', 'digital_state'])
                  DropdownMenuItem(
                    value: kind,
                    child: Text(tr(kind == 'custom' ? 'observationVoltageType' : measurementPointKinds[kind]!), maxLines: 3),
                  ),
              ],
              validator: (value) => !unused(point) && value == null ? tr('observationChooseType') : null,
              onChanged: (value) => setState(() {
                if (value != 'custom' || !['supply', 'sensor_signal', 'dc_output'].contains(point.kind)) {
                  point.kind = value!;
                }
                point.typeSelected = true;
              }),
            ),
            const SizedBox(height: 8),
            Text(tr(!point.typeSelected ? 'observationChooseType' :
              point.kind == 'reported_state' ? 'observationReportedHelp' :
              point.kind == 'digital_state' ? 'observationPinHelp' :
              point.isNumber ? 'observationNumberHelp' :
              point.isText ? 'observationTextHelp' : 'observationVoltageHelp'),
              style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (point.isBoolean) ...[
              label,
              const SizedBox(height: 12),
              DropdownButtonFormField<bool>(
                itemHeight: null,
                isExpanded: true,
                isDense: false,
                key: ValueKey('${point.id}-expected-state'),
                initialValue: point.expectedState,
                decoration: InputDecoration(
                  label: RequiredLabel(tr('booleanExpectedValue')),
                ),
                items: [
                  DropdownMenuItem(
                    value: true,
                    child: Text(tr(point.kind == 'reported_state' ? 'observationYes' : 'booleanTrue'), maxLines: 2),
                  ),
                  DropdownMenuItem(
                    value: false,
                    child: Text(tr(point.kind == 'reported_state' ? 'observationNo' : 'booleanFalse'), maxLines: 2),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => point.expectedState = value),
                validator: (value) =>
                    value == null ? tr('fieldRequired') : null,
              ),
              const SizedBox(height: 8),
              Text(
                tr('booleanCriterionHelp'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else if (point.isText) ...[
              label,
              const SizedBox(height: 12),
              TextFormField(
                key: ValueKey('${point.id}-expected-text'),
                controller: point.expectedText,
                maxLength: 500,
                decoration: InputDecoration(label: RequiredLabel(tr('expectedTextLabel')),
                  helperText: tr('expectedTextHelp'), helperMaxLines: 3),
                validator: (value) => (value ?? '').trim().isEmpty ? tr('fieldRequired') : null,
              ),
            ] else if (point.isNumber) ...[
              label,
              const SizedBox(height: 12),
              TextFormField(
                key: ValueKey('${point.id}-unit'),
                controller: point.unit,
                maxLength: 24,
                decoration: InputDecoration(label: RequiredLabel(tr('sensorUnit')),
                  hintText: '°C, %, Hz, cm, degrees'),
                validator: (value) => (value ?? '').trim().isEmpty ||
                  ['V', 'mV', 'boolean', 'text'].contains(value?.trim())
                  ? tr('sensorUnitRequired') : null,
              ),
              const SizedBox(height: 12),
              rangeFields(point),
            ] else if (point.typeSelected) ...[
              label,
              const SizedBox(height: 10),
              rangeFields(point),
            ] else label,
          ],
        );
      },
    ),
  );

  Widget section(String title, String help) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(title), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(tr(help), style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );

  Widget example() => ExpansionTile(
    key: const ValueKey('specification-example'),
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 16),
    leading: const Icon(Icons.lightbulb_outline, size: 20),
    title: Text(tr('specificationExampleTitle')),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final pair in [
        ('specificationExampleWiringTitle', 'specificationExampleWiring'),
        ('specificationExampleLocationsTitle', 'specificationExampleLocations'),
        ('specificationExampleLimitsTitle', 'specificationExampleLimits'),
      ])
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(pair.$1), style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(tr(pair.$2), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
    ],
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
            'kind': point.kind,
            'label': point.label.text.trim(),
            'value_kind': point.isBoolean ? 'boolean' : point.isText ? 'text' : point.isNumber ? 'number' : 'voltage',
            if (point.isBoolean) 'expected_state': point.expectedState,
            if (point.isText) 'expected_text': point.expectedText.text.trim(),
            if (point.isNumber) ...{
              'unit': point.unit.text.trim(),
              'min_value': voltage(point.minimum.text),
              'max_value': voltage(point.maximum.text),
            },
            if (!point.isBoolean && !point.isNumber && !point.isText) ...{
              'min_v': voltage(point.minimum.text),
              'max_v': voltage(point.maximum.text),
            },
          },
      ],
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: formDialogInsets(context),
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
              const RequiredFieldsNotice(),
              if (widget.project.trim().isNotEmpty) ...[
                Text(widget.project.trim(), style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 12),
              ],
              Text(tr('physicallyConfirmTheConnectionsDefineTheRangesThat')),
              example(),
              const SizedBox(height: 14),
              section('specificationWiringTitle', 'specificationWiringHelp'),
              TextFormField(
                controller: connections,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  label: RequiredLabel(tr('confirmedConnectionsOnePerLine')),
                  hintText: tr('specificationWiringPlaceholder'),
                  hintMaxLines: 3,
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
              const SizedBox(height: 22),
              section(
                'specificationOperationTitle',
                'specificationOperationHelp',
              ),
              TextFormField(
                controller: description,
                minLines: 2,
                maxLines: 5,
                maxLength: 1000,
                decoration: InputDecoration(
                  label: RequiredLabel(tr('functionalTestCondition')),
                  hintText: tr('specificationOperationPlaceholder'),
                  hintMaxLines: 3,
                ),
                validator: (value) => (value ?? '').trim().length < 5
                    ? tr('functionalDescriptionRequired')
                    : null,
              ),
              const SizedBox(height: 22),
              section('specificationLocationsTitle', 'measurementPointHelp'),
              Text(tr('specificationExpectedLimitsHelp')),
              const SizedBox(height: 12),
              Text(tr('testPointRequiredNotice')),
              const SizedBox(height: 12),
              for (final point in points) pointFields(point),
              OutlinedButton.icon(
                key: const ValueKey('add-test-point'),
                onPressed: points.length < maximumObservationPoints ? addPoint : null,
                icon: const Icon(Icons.add),
                label: Text(tr('addTestPoint')),
              ),
              const SizedBox(height: 12),
              Text(tr('testPointLimit', {'count': '$maximumObservationPoints'})),
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
