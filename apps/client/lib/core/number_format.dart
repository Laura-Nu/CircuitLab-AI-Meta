/// Presentation only: never changes a stored reading or its precision.
String formatNumber(num value, {String language = 'en', int? decimalPlaces}) {
  var text = decimalPlaces == null
      ? value.toString()
      : value.toStringAsFixed(decimalPlaces);
  if (text.contains('.') && !text.toLowerCase().contains('e')) {
    text = text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  if (text == '-0') text = '0';
  return language == 'es' ? text.replaceAll('.', ',') : text;
}
