const measurementPointKinds = <String, String>{
  'supply': 'measurementKindSupply',
  'sensor_signal': 'measurementKindSensor',
  'dc_output': 'measurementKindDcOutput',
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
