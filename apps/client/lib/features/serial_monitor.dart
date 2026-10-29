import 'dart:async';
import 'package:flutter/material.dart';
import '../core/networking/api.dart';
import '../core/usb_serial.dart';
import '../l10n/app_strings.dart';

/// Passive board output. Saving is explicit; firmware text never becomes an ADC reading.
class SerialMonitor extends StatefulWidget {
  final CircuitApi api;
  final String sessionId;
  final bool canSave;
  final Future<void> Function() onSaved;
  final UsbSerialPort? serial;
  const SerialMonitor({super.key, required this.api, required this.sessionId,
    required this.canSave, required this.onSaved, this.serial});
  @override
  State<SerialMonitor> createState() => _SerialMonitorState();
}

class _SerialMonitorState extends State<SerialMonitor> {
  late final port = widget.serial ?? UsbSerialPort();
  Timer? timer;
  int baudRate = 115200, sequence = 0, savedSequence = 0, dropped = 0;
  int generation = 0;
  bool connected = false, connecting = false, saving = false;
  List<String> lines = [];
  String? error;
  String? captureId;
  List<String>? captureLines;
  int captureSequence = 0;
  int captureBaudRate = 115200;

  @override
  void initState() {
    super.initState();
    widget.api.addListener(authChanged);
  }

  void authChanged() {
    if (!widget.api.signedIn && (connected || connecting)) unawaited(disconnect());
  }

  void poll() {
    if (!mounted) return;
    final snapshot = port.monitorSnapshot();
    setState(() {
      connected = snapshot['connected'] == true;
      if (connected) {
        lines = List<String>.from(snapshot['lines']);
        sequence = snapshot['sequence'] as int;
        dropped = snapshot['dropped'] as int;
      }
    });
    if (!connected) { timer?.cancel(); timer = null; }
  }

  Future<void> connect() async {
    final attempt = ++generation;
    setState(() { connecting = true; error = null; });
    try {
      final result = await port.connectMonitor(baudRate);
      if (!mounted || attempt != generation) return;
      if (result['status'] != 'connected') {
        final status = result['status'];
        final key = status == 'busy' ? 'serialBusy' : status == 'cancelled' ? 'serialCancelled'
          : status == 'permission_denied' ? 'serialPermissionDenied' : 'serialConnectionError';
        setState(() => error = AppStrings.of(context).t(key));
        return;
      }
      lines = []; sequence = 0; savedSequence = 0; captureId = null; captureLines = null;
      poll();
      timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
    } catch (e) {
      if (mounted && attempt == generation) setState(() => error = errorMessage(e, language: widget.api.language));
    } finally {
      if (mounted && attempt == generation) setState(() => connecting = false);
    }
  }

  Future<void> disconnect() async {
    ++generation;
    timer?.cancel(); timer = null;
    await port.disconnect();
    if (mounted) setState(() { connected = false; connecting = false; });
  }

  Future<void> save() async {
    // Reuse the exact payload/id after uncertain delivery; do not create duplicates.
    if (captureId == null) {
      captureId = clientId(); captureLines = List<String>.of(lines);
      captureSequence = sequence; captureBaudRate = baudRate;
    }
    setState(() { saving = true; error = null; });
    try {
      await widget.api.request('/sessions/${widget.sessionId}/serial-captures', method: 'POST', data: {
        'client_id': captureId, 'baud_rate': captureBaudRate, 'lines': captureLines,
      });
      if (!mounted) return;
      setState(() { savedSequence = captureSequence; captureId = null; captureLines = null; });
      await widget.onSaved();
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e, language: widget.api.language));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    ++generation;
    widget.api.removeListener(authChanged);
    timer?.cancel();
    // Never close a fixed-protocol instrument owned by another controller.
    if (connected || connecting) unawaited(port.disconnect());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return ExpansionTile(
      key: const PageStorageKey('serial-monitor'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(strings.t('serialMonitorTitle')),
      subtitle: Text(strings.t('serialMonitorSubtitle')),
      leading: const Icon(Icons.usb),
      childrenPadding: const EdgeInsets.only(bottom: 20),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(strings.t('serialMonitorHelp')),
        const SizedBox(height: 16),
        if (!port.supported) Text(strings.t('serialUnsupported')) else ...[
          DropdownButtonFormField<int>(
            initialValue: baudRate, isExpanded: true, isDense: false, itemHeight: null,
            decoration: InputDecoration(labelText: strings.t('serialBaudRate')),
            items: [for (final baud in [9600, 19200, 38400, 57600, 115200])
              DropdownMenuItem(value: baud, child: Text('$baud baud'))],
            onChanged: connected || connecting || saving ? null : (value) => setState(() => baudRate = value!),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, constraints) {
            final buttons = <Widget>[
              OutlinedButton.icon(
                onPressed: saving ? null : connected || connecting ? disconnect : connect,
                icon: Icon(connected || connecting ? Icons.close : Icons.usb),
                label: Text(strings.t(connected || connecting ? 'serialDisconnect' : 'serialConnect'),
                  textAlign: TextAlign.center),
              ),
              FilledButton.icon(
                onPressed: widget.canSave && !saving && lines.isNotEmpty && sequence != savedSequence ? save : null,
                icon: const Icon(Icons.save_outlined),
                label: Text(strings.t(saving ? 'serialSaving' : 'serialSave'), textAlign: TextAlign.center),
              ),
            ];
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            return constraints.maxWidth / textScale < 480
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [buttons.first, const SizedBox(height: 12), buttons.last])
              : Wrap(spacing: 12, runSpacing: 12, children: buttons);
          }),
          const SizedBox(height: 12),
          Text(strings.t(connecting ? 'serialConnecting' : connected ? 'serialListening' : 'serialDisconnected')),
          if (lines.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(strings.t('serialWaiting')))
          else Container(
            constraints: const BoxConstraints(maxHeight: 240),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(child: SelectableText(lines.join('\n'))),
          ),
          if (dropped > 0) Text(strings.t('serialBufferLimit')),
          if (savedSequence > 0) Text(strings.t('serialSaved')),
        ],
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
