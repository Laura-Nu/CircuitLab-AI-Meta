import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

const programFileSupported = true;

/// Read text only; never upload firmware to the board or execute the source.
Future<String?> pickProgramFile() async {
  final result = Completer<String?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.ino,.cpp,.h,.hpp,.c,.py,.txt';
  input.addEventListener('cancel', ((web.Event _) {
    if (!result.isCompleted) {
      result.complete(null);
    }
  }).toJS);
  input.addEventListener('change', ((web.Event _) {
    Future<void> read() async {
      try {
        final file = input.files?.item(0);
        if (file == null) {
          result.complete(null);
        } else {
          if (file.size > 100000) {
            throw const FormatException('Program too large');
          }
          final content = (await file.text().toDart).toDart;
          if (content.length > 20000) {
            throw const FormatException('Program too large');
          }
          result.complete(content);
        }
      } catch (error, stack) {
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      }
    }
    unawaited(read());
  }).toJS);
  input.click();
  return result.future;
}
