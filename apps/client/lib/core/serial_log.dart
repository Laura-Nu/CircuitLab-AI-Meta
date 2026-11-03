/// Recognize explicit log severity, never turn prose or an error into a reading.
List<String> serialErrorMessages(List<String> lines) {
  final severity = RegExp(
    r'^(?:\[[^\]]+\]\s*)?(?:ERROR\s*[:\-]|FATAL\b|FAILED\b|FALLO\s*[:\-]|REGISTRO CANCELADO\b)',
    caseSensitive: false,
  );
  return lines.where((line) => severity.hasMatch(line.trim()))
      .toSet().toList().reversed.take(4).toList();
}
