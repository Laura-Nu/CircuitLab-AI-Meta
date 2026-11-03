import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../core/networking/api.dart';
import '../core/measurement_points.dart';
import '../core/serial_log.dart';
import '../core/usb_serial.dart';
import '../l10n/app_strings.dart';
import 'observation_readout.dart';

/// Board-reported data stays separate from the calibrated ADC/GPIO instrument.
class SerialMonitor extends StatefulWidget {
  final CircuitApi api;
  final String sessionId;
  final bool canSave;
  final Future<void> Function() onSaved;
  final UsbSerialPort? serial;
  final Map<String, dynamic> session;
  final ExpansibleController? expansionController;
  final bool? initiallyExpanded;
  final bool maintainConnection;
  final VoidCallback? onProgram;
  const SerialMonitor({super.key, required this.api, required this.sessionId,
    required this.canSave, required this.onSaved, this.serial, this.session = const {},
    this.expansionController, this.initiallyExpanded, this.maintainConnection = false,
    this.onProgram});
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
  List<Map<String, dynamic>> observations = [];
  final bindings = <String, String>{};
  final submitted = <String>{};
  bool automatic = false, recording = false;
  int freshAfter = 0;
  Map<String, dynamic>? pendingReading;
  int? waitingVersion;

  int currentSequence() => (port.monitorSnapshot()['sequence'] as num?)?.toInt() ?? sequence;

  List<Map> get points => (widget.session['specification']?['points'] as List? ?? []).cast<Map>();
  String requestKey(Map session) => '${session['spec_version']}:${session['analysis_steps']}:'
      '${session['state']}:${session['pending_test']?['point_id']}:'
      '${session['pending_test']?['requested_at']}:${session['pending_test']?['after']}';
  List<Map> get requestedPoints {
    if (widget.session['state'] == 'awaiting_measurement') {
      return points.where((point) => point['id'] == widget.session['pending_test']?['point_id']).toList();
    }
    if (widget.session['state'] == 'verifying') {
      final missing = widget.session['completion']?['missing_points'] as List? ?? [];
      return points.where((point) => missing.contains(point['id'])).toList();
    }
    return [];
  }

  @override
  void didUpdateWidget(covariant SerialMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      automatic = false;
      bindings.clear(); submitted.clear(); observations = []; lines = []; waitingVersion = null;
      captureId = null; captureLines = null; savedSequence = 0;
      pendingReading = null;
      if (!widget.maintainConnection && (connected || connecting)) unawaited(disconnect());
    }
    if (requestKey(oldWidget.session) != requestKey(widget.session)) {
      // A buffered sample from the previous request must never answer a new test.
      freshAfter = currentSequence();
      submitted.clear();
      pendingReading = null;
    }
    if (oldWidget.session['spec_version'] != widget.session['spec_version'] ||
        oldWidget.session['pending_test']?['after'] != widget.session['pending_test']?['after']) {
      automatic = false;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.api.addListener(authChanged);
    if (widget.maintainConnection && port.monitorSnapshot()['connected'] == true) {
      baudRate = (port.monitorSnapshot()['baud_rate'] as num?)?.toInt() ?? baudRate;
      poll();
      freshAfter = sequence;
      timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
    }
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
        observations = (snapshot['observations'] as List? ?? [])
            .map((sample) => Map<String, dynamic>.from(sample as Map)).toList();
      } else {
        automatic = false;
        observations = [];
      }
    });
    if (!connected) { timer?.cancel(); timer = null; }
    if (connected && automatic && !recording && !saving && widget.canSave) {
      unawaited(recordNext());
    }
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
      automatic = false; bindings.clear(); submitted.clear(); pendingReading = null; waitingVersion = null;
      poll();
      freshAfter = sequence;
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
    if (mounted) {
      setState(() {
        connected = false; connecting = false; automatic = false; observations = [];
      });
    }
  }

  Future<void> recordNext() async {
    if (!widget.api.signedIn || requestedPoints.isEmpty) return;
    // A coalesced refresh may return before the acknowledged server version arrives.
    if (waitingVersion != null && (widget.session['version'] as num? ?? 0) <= waitingVersion!) return;
    waitingVersion = null;
    final after = widget.session['pending_test']?['requested_at'] ?? widget.session['pending_test']?['after'] ?? 0;
    Map? selected;
    Map<String, dynamic>? sample;
    for (final point in requestedPoints) {
      if (submitted.contains('${requestKey(widget.session)}:${point['id']}')) continue;
      for (final observation in observations) {
        if (bindings[point['id']] == observation['channel'] &&
            serialSupportsObservation(point, observation) &&
            (observation['sequence'] as num) > freshAfter &&
            (observation['received_at'] as num) >= (after as num) &&
            DateTime.now().millisecondsSinceEpoch / 1000 - (observation['received_at'] as num) <= 10) {
          selected = point; sample = observation; break;
        }
      }
      if (selected != null) break;
    }
    final request = requestKey(widget.session);
    final attempt = generation;
    if (pendingReading == null) {
      if (selected == null || sample == null) return;
      pendingReading = {
        'client_id': clientId(), 'point_id': selected['id'], 'line': sample['line'],
        'received_at': sample['received_at'], 'conditions_confirmed': true,
        'spec_version': widget.session['spec_version'], 'request_version': widget.session['version'],
      };
    }
    final payload = pendingReading!;
    setState(() => recording = true);
    try {
      await widget.api.request('/sessions/${widget.sessionId}/serial-readings', method: 'POST', data: payload);
      if (!mounted || generation != attempt || requestKey(widget.session) != request) return;
      submitted.add('$request:${payload['point_id']}');
      waitingVersion = (payload['request_version'] as num).toInt();
      pendingReading = null;
      await widget.onSaved();
    } catch (e) {
      if (!mounted || generation != attempt || requestKey(widget.session) != request) return;
      // Retry uncertain delivery with the same payload; discard a definite rejection.
      if (e is DioException && e.response != null && (e.response!.statusCode ?? 500) < 500) pendingReading = null;
      setState(() { automatic = false; error = errorMessage(e, language: widget.api.language); });
    } finally {
      if (mounted) setState(() => recording = false);
    }
  }

  Future<void> save({bool analyze = false}) async {
    final destination = widget.sessionId;
    // Reuse the exact payload/id after uncertain delivery; do not create duplicates.
    if (captureId == null) {
      captureId = clientId(); captureLines = List<String>.of(lines);
      captureSequence = sequence; captureBaudRate = baudRate;
    }
    setState(() { saving = true; error = null; });
    try {
      final capture = await widget.api.request('/sessions/$destination/serial-captures', method: 'POST', data: {
        'client_id': captureId, 'baud_rate': captureBaudRate, 'lines': captureLines,
      });
      if (!mounted || widget.sessionId != destination) return;
      if (analyze) {
        await widget.api.request('/sessions/$destination/analysis', method: 'POST',
          data: {'evidence_id': capture['id']});
      }
      if (!mounted || widget.sessionId != destination) return;
      setState(() { savedSequence = captureSequence; captureId = null; captureLines = null; });
      await widget.onSaved();
    } catch (e) {
      if (mounted && widget.sessionId == destination) {
        setState(() {
          if (e is DioException && e.response != null && (e.response!.statusCode ?? 500) < 500) {
            captureId = null; captureLines = null;
          }
          error = errorMessage(e, language: widget.api.language);
        });
      }
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
    if (connecting || (connected && !widget.maintainConnection)) unawaited(port.disconnect());
    super.dispose();
  }

  Widget automaticReadings(AppStrings strings) {
    String sampleValue(Map sample) => sample['unit'] == 'boolean'
        ? strings.t(sample['value'] == true ? 'observationYes' : 'observationNo')
        : strings.observation(sample['value'], sample['unit']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Text(strings.t('serialChannelsTitle'), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(strings.t('serialChannelsHelp')),
      if (observations.isNotEmpty) ExpansionTile(
        key: const PageStorageKey('serial-available-channels'),
        initiallyExpanded: true,
        tilePadding: EdgeInsets.zero,
        title: Text(strings.t('serialAvailableChannels', {'count': observations.length})),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final sample in observations) Builder(builder: (_) {
          final linked = points.where((point) => bindings[point['id']] == sample['channel']).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final point in linked.isEmpty ? <Map>[{}] : linked)
              ObservationReadout(
                key: ValueKey('serial-reading-${sample['channel']}-${point['id'] ?? ''}'),
                title: '${point['label'] ?? sample['label'] ?? sample['channel']}',
                observation: sample, point: point, live: true,
              ),
            const Divider(height: 1),
          ]);
        })],
      ),
      if (observations.any((sample) => sample['invalid'] == true)) Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(strings.t('serialInvalidChannels', {
          'count': observations.where((sample) => sample['invalid'] == true).length,
        }), style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
      if (points.isEmpty) Padding(
        padding: const EdgeInsets.only(top: 12), child: Text(strings.t('serialConfirmCriteria')),
      ),
      if (observations.isEmpty && lines.isNotEmpty) Padding(
        padding: const EdgeInsets.only(top: 12), child: Text(strings.t('serialTextOnlyHelp')),
      ),
      for (final point in observations.isEmpty ? <Map>[] : points) Builder(builder: (context) {
        final compatible = observations.where((sample) => serialSupportsObservation(point, sample)).toList();
        final chosen = compatible.any((sample) => sample['channel'] == bindings[point['id']])
            ? bindings[point['id']] : null;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DropdownButtonFormField<String>(
            key: ValueKey('serial-channel-${point['id']}-$chosen'),
            initialValue: chosen, isExpanded: true, isDense: false, itemHeight: null,
            decoration: InputDecoration(labelText: '${point['label']}',
              helperText: compatible.isEmpty ? strings.t('serialNoMatchingChannel') : strings.criterion(point),
              helperMaxLines: 4),
            hint: Text(strings.t('serialChooseChannel')),
            items: [for (final sample in compatible) DropdownMenuItem(
              value: sample['channel'] as String,
              child: Text('${sample['sensor'] ?? sample['board'] ?? ''} ${sample['channel']} · '
                  '${sampleValue(sample)}'.trim(), maxLines: 4),
            )],
            onChanged: recording || compatible.isEmpty ? null : (value) => setState(() {
              bindings[point['id'] as String] = value!;
              automatic = false; pendingReading = null; freshAfter = currentSequence();
            }),
          ),
        );
      }),
      if (points.isNotEmpty && observations.isNotEmpty) SwitchListTile(
        key: const ValueKey('serial-automatic'),
        contentPadding: EdgeInsets.zero,
        title: Text(strings.t('serialAutomatic')),
        subtitle: Text(strings.t('serialAutomaticConsent')),
        value: automatic,
        onChanged: !recording && (automatic || (widget.canSave && bindings.isNotEmpty))
            ? (value) => setState(() { automatic = value; freshAfter = currentSequence(); error = null; }) : null,
      ),
      if (automatic) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(
        strings.t(recording ? 'serialRecording' : requestedPoints.isEmpty ? 'serialAutoPaused' : 'serialAutoWaiting'),
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      )),
      if (observations.isEmpty || observations.every((sample) => sample['invalid'] == true)) ExpansionTile(
        key: const PageStorageKey('serial-format-help'),
        tilePadding: EdgeInsets.zero,
        title: Text(strings.t('serialFormatTitle')),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(strings.t('serialFormatHelp')),
          const SizedBox(height: 8),
          const SelectableText('{"circuitlab":1,"channel":"dht11.temperature",'
              '"sensor":"DHT11","value":23.5,"unit":"°C"}',
              key: PageStorageKey('serial-format-example')),
          const SizedBox(height: 12),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final reportedErrors = serialErrorMessages(lines);
    return ExpansionTile(
      controller: widget.expansionController,
      // Expansion flags and scroll offsets must have distinct storage identifiers.
      key: PageStorageKey('serial-monitor-${widget.sessionId}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(strings.t('serialMonitorTitle')),
      subtitle: Text(strings.t(connected ? 'serialConnectedSummary' : 'serialMonitorSubtitle')),
      leading: const Icon(Icons.usb),
      initiallyExpanded: widget.initiallyExpanded ?? widget.session.isNotEmpty,
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
                onPressed: widget.canSave && !recording && !saving && lines.isNotEmpty && sequence != savedSequence ? save : null,
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
          if (reportedErrors.isNotEmpty) Padding(
            key: const ValueKey('serial-reported-errors'),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(strings.t('serialErrorsTitle'), style: Theme.of(context).textTheme.titleMedium),
              for (final message in reportedErrors) Padding(
                padding: const EdgeInsets.only(top: 8), child: Text(message)),
              const SizedBox(height: 8),
              Text(strings.t('serialErrorsHelp')),
            ]),
          ),
          if (widget.sessionId.isNotEmpty && lines.isNotEmpty) Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Wrap(spacing: 12, runSpacing: 12, children: [
              FilledButton.icon(
                key: const ValueKey('serial-analyze-messages'),
                onPressed: widget.canSave && !saving && !recording &&
                    ['ready', 'awaiting_evidence', 'awaiting_confirmation', 'awaiting_measurement']
                        .contains(widget.session['state']) ? () => save(analyze: true) : null,
                icon: const Icon(Icons.troubleshoot), label: Text(strings.t('serialAnalyzeMessages')),
              ),
              if (widget.onProgram != null) OutlinedButton.icon(
                onPressed: widget.canSave && !saving && !recording ? widget.onProgram : null,
                icon: const Icon(Icons.code), label: Text(strings.t('attachProgram')),
              ),
            ]),
          ),
          if (connected) automaticReadings(strings),
          if (lines.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(strings.t('serialWaiting')))
          else ExpansionTile(
            key: const PageStorageKey('serial-raw-messages'),
            tilePadding: EdgeInsets.zero,
            title: Text(strings.t('serialRawMessages', {'count': lines.length})),
            subtitle: Text(strings.t('serialRawMessagesHelp')),
            children: [Container(
              constraints: const BoxConstraints(maxHeight: 240),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                key: const PageStorageKey('serial-output-scroll'),
                primary: false,
                child: SelectableText(lines.join('\n'),
                  key: const PageStorageKey('serial-output-text')),
              ),
            )],
          ),
          if (dropped > 0) Text(strings.t('serialBufferLimit')),
          if (savedSequence > 0) Text(strings.t('serialSaved')),
        ],
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
