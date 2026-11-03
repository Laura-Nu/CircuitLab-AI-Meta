const maximumObservationPoints = 32;

const measurementPointKinds = <String, String>{
  'supply': 'measurementKindSupply',
  'sensor_signal': 'measurementKindSensor',
  'dc_output': 'measurementKindDcOutput',
  'digital_state': 'measurementKindDigital',
  'reported_state': 'measurementKindReportedState',
  'numeric': 'measurementKindNumber',
  'text': 'measurementKindText',
  'custom': 'measurementKindCustom',
};

/// Names are for people; stable IDs remain the request and bridge identifiers.
String measurementPointName(
  Map specification,
  dynamic pointId, {
  bool includeReference = false,
}) {
  final id = pointId?.toString() ?? '';
  final points = specification['points'] as List? ?? [];
  for (final point in points) {
    if (point['id'] != id) continue;
    final label = (point['label'] as String? ?? '').trim();
    if (label.isNotEmpty) {
      final ambiguous =
          points
              .where(
                (p) =>
                    (p['label'] as String? ?? '').trim().toLowerCase() ==
                    label.toLowerCase(),
              )
              .length >
          1;
      return includeReference || ambiguous ? '$label ($id)' : label;
    }
  }
  return id;
}

Map measurementPoint(Map specification, dynamic pointId) =>
    (specification['points'] as List? ?? []).cast<Map>().firstWhere(
      (point) => point['id'] == pointId,
      orElse: () => {},
    );

bool booleanPoint(Map specification, dynamic pointId) =>
    measurementPoint(specification, pointId)['value_kind'] == 'boolean';

bool instrumentSupportsObservation(Map point) =>
    point['kind'] != 'reported_state' &&
    const ['voltage', 'boolean'].contains(point['value_kind'] ?? 'voltage');

/// Match explicit units and JSON types; a channel name never implies a unit.
bool serialSupportsObservation(Map point, Map sample) {
  final value = sample['value'], unit = sample['unit'];
  return switch (point['value_kind'] ?? 'voltage') {
    'boolean' => unit == 'boolean' && value is bool,
    'text' => unit == 'text' && value is String,
    'number' => unit == point['unit'] && value is num && value.isFinite,
    _ => (unit == 'V' || unit == 'mV') && value is num && value.isFinite,
  };
}

/// Compare explicit types/units only. An unavailable comparison is not a pass.
bool? observationMatchesCriterion(Map point, dynamic value, String unit) {
  if (!serialSupportsObservation(point, {'value': value, 'unit': unit})) {
    return null;
  }
  switch (point['value_kind'] ?? 'voltage') {
    case 'boolean':
      return point['expected_state'] is bool
          ? value == point['expected_state'] : null;
    case 'text':
      return point['expected_text'] is String
          ? value == point['expected_text'] : null;
    default:
      final numeric = point['value_kind'] == 'number';
      final minimum = point[numeric ? 'min_value' : 'min_v'];
      final maximum = point[numeric ? 'max_value' : 'max_v'];
      if (minimum is! num || maximum is! num ||
          !minimum.isFinite || !maximum.isFinite || minimum > maximum) {
        return null;
      }
      final reading = !numeric && unit == 'mV' ? (value as num) / 1000 : value as num;
      return reading >= minimum && reading <= maximum;
  }
}
