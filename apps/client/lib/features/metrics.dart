import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/networking/api.dart';
import '../l10n/app_strings.dart';
import '../main.dart' show mint, muted;

class MetricsPanel extends StatefulWidget {
  final CircuitApi api;
  const MetricsPanel({super.key, required this.api});
  @override
  State<MetricsPanel> createState() => _MetricsPanelState();
}

class _MetricsPanelState extends State<MetricsPanel> {
  Map<String, dynamic>? data;
  int days = 30;
  String mode = 'real', series = 'requests';
  bool busy = false;
  String? error;
  Timer? timer;
  int? hovered;
  AppStrings get strings => AppStrings.of(context);
  String tr(String key, [Map<String, Object?> args = const {}]) =>
      strings.t(key, args);
  Map<String, dynamic> map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  String count(dynamic value) => MaterialLocalizations.of(
    context,
  ).formatDecimal((value as num? ?? 0).round());
  String decimal(num value) => value
      .toStringAsFixed(1)
      .replaceAll('.', strings.language == 'es' ? ',' : '.');
  String duration(dynamic value) => value is! num
      ? '—'
      : value < 1000
      ? '${count(value)} ms'
      : '${decimal(value / 1000)} s';

  @override
  void initState() {
    super.initState();
    if (widget.api.isAdmin) load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (widget.api.isAdmin && !busy) load();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (busy || !widget.api.isAdmin) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        '/admin/metrics?days=$days&mode=$mode',
      );
      if (mounted) {
        setState(() {
          data = map(result);
          hovered = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = errorMessage(e, language: widget.api.language));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String timestamp(dynamic epoch) {
    if (epoch is! num) return '—';
    final date = DateTime.fromMillisecondsSinceEpoch(
      (epoch * 1000).round(),
    ).toLocal();
    final locale = MaterialLocalizations.of(context);
    return '${locale.formatCompactDate(date)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: true)}';
  }

  Widget box(String title, Widget child, {String? subtitle}) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: muted, fontSize: 12)),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.api.isAdmin) return Text(tr('metricsAdminOnly'));
    final inference = map(data?['inference']), runtime = map(data?['runtime']);
    final queue = map(data?['queue']), sessions = map(data?['sessions']);
    final daily = (data?['daily'] as List? ?? []).map(map).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 20,
          runSpacing: 16,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('metricsTitle'),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  tr('metricsSubtitle'),
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : load,
              icon: const Icon(Icons.refresh),
              label: Text(tr('metricsRefresh')),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 175,
              child: DropdownButtonFormField<int>(
                key: ValueKey('metrics-days-$days'),
                initialValue: days,
                decoration: InputDecoration(labelText: tr('metricsPeriod')),
                items: [7, 30, 90]
                    .map(
                      (d) => DropdownMenuItem(
                        value: d,
                        child: Text(tr('metricsDays', {'days': d})),
                      ),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (d) {
                        if (d != null) {
                          setState(() => days = d);
                          load();
                        }
                      },
              ),
            ),
            SizedBox(
              width: 230,
              child: DropdownButtonFormField<String>(
                key: ValueKey('metrics-mode-$mode'),
                initialValue: mode,
                decoration: InputDecoration(
                  labelText: tr('metricsInferenceMode'),
                ),
                items: ['real', 'simulation', 'all']
                    .map(
                      (m) => DropdownMenuItem(
                        value: m,
                        child: Text(tr('metricsMode_$m')),
                      ),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (m) {
                        if (m != null) {
                          setState(() => mode = m);
                          load();
                        }
                      },
              ),
            ),
            if (data != null)
              Text(
                tr('metricsUpdated', {
                  'time': timestamp(data!['generated_at']),
                }),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 18),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '${tr('metricsRefreshFailed')} $error',
              style: const TextStyle(color: Colors.amber),
            ),
          ),
        if (data == null && !busy && error == null) Text(tr('metricsNoData')),
        if (data != null) ...[
          const SizedBox(height: 18),
          box(
            tr('metricsRuntime'),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                Text('${tr('metricsProvider')}: ${runtime['provider'] ?? '—'}'),
                Text('${tr('metricsModel')}: ${runtime['model'] ?? '—'}'),
                Text(
                  tr(
                    runtime['ai_mode'] == 'simulation'
                        ? 'metricsRuntimeSimulation'
                        : 'metricsRuntimeReal',
                  ),
                  style: TextStyle(
                    color: runtime['ai_mode'] == 'simulation'
                        ? Colors.amber
                        : mint,
                  ),
                ),
                Text(
                  tr(
                    runtime['configured'] == true
                        ? 'metricsConfigured'
                        : 'metricsUnconfigured',
                  ),
                ),
                Text(
                  tr('metricsLastCall', {
                    'time': timestamp(runtime['last_recorded_call']),
                  }),
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
            subtitle: tr('metricsRuntimeNotice'),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1040
                  ? 4
                  : constraints.maxWidth >= 710
                  ? 3
                  : constraints.maxWidth >= 470
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 14) / columns;
              final rate = inference['http_success_rate'];
              final cards = [
                (
                  tr('metricsRequests'),
                  count(inference['requests']),
                  tr('metricsRequestsNote'),
                ),
                (
                  tr('metricsHttpSuccess'),
                  rate is num ? '${decimal(rate)}%' : '—',
                  tr('metricsHttpSuccessNote'),
                ),
                (
                  tr('metricsLatency'),
                  duration(inference['p95_latency_ms']),
                  tr('metricsLatencyNote', {
                    'samples': count(inference['latency_samples']),
                  }),
                ),
                (
                  tr('metricsTokens'),
                  count(inference['total_tokens']),
                  tr('metricsTokenParts', {
                    'input': count(inference['prompt_tokens']),
                    'output': count(inference['completion_tokens']),
                  }),
                ),
                (
                  tr('metricsAccepted'),
                  count(inference['accepted_diagnoses']),
                  tr('metricsAcceptedNote'),
                ),
                (
                  tr('metricsRejected'),
                  count(inference['failed_diagnostic_attempts']),
                  tr('metricsRejectedNote'),
                ),
                (
                  tr('metricsToolExecutions'),
                  count(inference['tool_executions']),
                  tr('metricsToolNote'),
                ),
                (
                  tr('metricsSimulationSteps'),
                  count(inference['simulation_steps']),
                  tr('metricsSimulationNote'),
                ),
              ];
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: cards
                    .map(
                      (item) => SizedBox(
                        width: width,
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.$1,
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  item.$2,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineLarge
                                      ?.copyWith(color: mint),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.$3,
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 18),
          box(
            tr('metricsTrend'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ['requests', 'tokens', 'latency']
                      .map(
                        (value) => ChoiceChip(
                          selected: series == value,
                          label: Text(tr('metricsSeries_$value')),
                          onSelected: (_) => setState(() {
                            series = value;
                            hovered = null;
                          }),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 18),
                if (daily.isNotEmpty)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final primary = daily
                          .map<double?>(
                            (d) =>
                                (d[series == 'latency'
                                            ? 'mean_latency_ms'
                                            : series]
                                        as num?)
                                    ?.toDouble(),
                          )
                          .toList();
                      final failed = daily
                          .map<double?>(
                            (d) =>
                                ((d['http_errors'] as num? ?? 0) +
                                        (d['transport_errors'] as num? ?? 0))
                                    .toDouble(),
                          )
                          .toList();
                      final simulated = daily
                          .map<double?>(
                            (d) =>
                                (d['simulation_steps'] as num? ?? 0).toDouble(),
                          )
                          .toList();
                      return Semantics(
                        label: tr('metricsChartAccessible'),
                        child: MouseRegion(
                          onHover: (event) => setState(
                            () => hovered =
                                (((event.localPosition.dx - 42) /
                                            math.max(
                                              1,
                                              constraints.maxWidth - 55,
                                            )) *
                                        (daily.length - 1))
                                    .round()
                                    .clamp(0, daily.length - 1),
                          ),
                          onExit: (_) => setState(() => hovered = null),
                          child: GestureDetector(
                            onTapDown: (event) => setState(
                              () => hovered =
                                  (((event.localPosition.dx - 42) /
                                              math.max(
                                                1,
                                                constraints.maxWidth - 55,
                                              )) *
                                          (daily.length - 1))
                                      .round()
                                      .clamp(0, daily.length - 1),
                            ),
                            child: CustomPaint(
                              size: Size(constraints.maxWidth, 220),
                              painter: _TrendPainter(
                                primary,
                                secondary: series == 'requests' ? failed : [],
                                simulated:
                                    series == 'requests' && mode != 'real'
                                    ? simulated
                                    : [],
                                hovered: hovered,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                if (daily.isNotEmpty)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        daily.first['day'],
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                      Text(
                        daily.last['day'],
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: [
                    legend(mint, tr('metricsSeries_$series')),
                    if (series == 'requests')
                      legend(
                        Colors.deepOrangeAccent,
                        tr('metricsRequestErrors'),
                      ),
                    if (series == 'requests' && mode != 'real')
                      legend(
                        Colors.lightBlueAccent,
                        tr('metricsSimulationSteps'),
                      ),
                  ],
                ),
                if (hovered != null && hovered! < daily.length)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '${daily[hovered!]['day']} · ${series == 'latency' ? duration(daily[hovered!]['mean_latency_ms']) : count(daily[hovered!][series])}',
                      style: const TextStyle(color: mint),
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  tr('metricsUtcNotice'),
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                if ((inference['requests'] as num? ?? 0) == 0 &&
                    (inference['simulation_steps'] as num? ?? 0) == 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(tr('metricsNoData')),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 780;
              final width = wide
                  ? (constraints.maxWidth - 18) / 2
                  : constraints.maxWidth;
              final states = map(sessions['current_states']),
                  measurements = map(data!['measurements']);
              return Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  SizedBox(
                    width: width,
                    child: box(
                      tr('metricsSessions'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (states.isEmpty) Text(tr('metricsNoData')),
                          ...states.entries.map(
                            (e) => bar(
                              stateLabel(e.key),
                              e.value as num,
                              sessions['created'] as num? ?? 0,
                              mint,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            tr('metricsPhysicalVerifications', {
                              'count': count(
                                sessions['physical_verifications'],
                              ),
                            }),
                            style: const TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
                      subtitle: tr('metricsSessionsNote'),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: box(
                      tr('metricsMeasurementSources'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ...['instrumented', 'manual', 'simulated'].map(
                            (source) => bar(
                              tr('metricsSource_$source'),
                              measurements[source] as num? ?? 0,
                              measurements.values.fold<num>(
                                0,
                                (sum, value) => sum + (value as num),
                              ),
                              source == 'simulated'
                                  ? Colors.amber
                                  : source == 'manual'
                                  ? Colors.lightBlueAccent
                                  : mint,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tr('metricsQueue', {
                              'pending': count(queue['pending']),
                              'running': count(queue['running']),
                            }),
                            style: const TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
                      subtitle: tr('metricsMeasurementNote'),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          box(
            tr('metricsModels'),
            horizontalTable(
              [
                tr('metricsProvider'),
                tr('metricsModel'),
                tr('metricsRequests'),
                tr('metricsRequestErrors'),
                tr('metricsTokens'),
              ],
              (data!['models'] as List? ?? []).map((v) {
                final m = map(v);
                return [
                  m['provider'].toString(),
                  m['model'].toString(),
                  count(m['requests']),
                  count(m['http_errors']),
                  count(m['tokens']),
                ];
              }).toList(),
            ),
          ),
          const SizedBox(height: 18),
          box(
            tr('metricsRecent'),
            horizontalTable(
              [
                tr('metricsLocalTime'),
                tr('metricsModel'),
                tr('metricsOutcome'),
                tr('metricsDuration'),
                tr('metricsTokens'),
              ],
              (data!['recent_calls'] as List? ?? []).map((v) {
                final call = map(v);
                return [
                  timestamp(call['created_at']),
                  '${call['provider']} / ${call['model']}',
                  call['outcome'] == 'http_ok'
                      ? 'HTTP ${call['http_status']}'
                      : call['outcome'] == 'http_error'
                      ? 'HTTP ${call['http_status']}'
                      : tr('metricsOutcome_${call['outcome']}'),
                  duration(call['duration_ms']),
                  call['usage_reported'] == true ? count(call['tokens']) : '—',
                ];
              }).toList(),
            ),
            subtitle: tr('metricsUsageNotice', {
              'known': count(inference['usage_reported_calls']),
              'total': count(inference['requests']),
            }),
          ),
          const SizedBox(height: 18),
          box(
            tr('metricsAccuracy'),
            Text(
              tr('metricsAccuracyNotice'),
              style: const TextStyle(color: muted),
            ),
            subtitle: tr('metricsAccuracyUnavailable'),
          ),
        ],
      ],
    );
  }

  String stateLabel(String state) {
    const keys = {
      'draft': 'draft',
      'ready': 'readyToAnalyze',
      'analyzing': 'analyzing',
      'awaiting_evidence': 'evidenceNeeded',
      'awaiting_confirmation': 'confirmAConnection',
      'awaiting_measurement': 'measurementPending',
      'awaiting_intervention': 'humanIntervention',
      'verifying': 'verifying',
      'resolved': 'criteriaMet',
      'inconclusive': 'inconclusive',
      'cancelled': 'cancelled',
    };
    return tr(keys[state] ?? 'metricsUnknown');
  }

  Widget legend(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 7),
      Text(label, style: const TextStyle(color: muted, fontSize: 11)),
    ],
  );
  Widget bar(String label, num value, num total, Color color) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(count(value), style: TextStyle(color: color)),
          ],
        ),
        const SizedBox(height: 7),
        LinearProgressIndicator(
          value: total > 0 ? (value / total).clamp(0.0, 1.0) : 0,
          color: color,
          backgroundColor: const Color(0xFF29343E),
          minHeight: 5,
          borderRadius: BorderRadius.circular(8),
        ),
      ],
    ),
  );
  Widget horizontalTable(List<String> columns, List<List<String>> rows) =>
      rows.isEmpty
      ? Text(tr('metricsNoData'))
      : SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 26,
            columns: columns.map((c) => DataColumn(label: Text(c))).toList(),
            rows: rows
                .map(
                  (r) => DataRow(
                    cells: r
                        .map(
                          (c) => DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 280),
                              child: Tooltip(
                                message: c,
                                child: Text(
                                  c,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                )
                .toList(),
          ),
        );
}

class _TrendPainter extends CustomPainter {
  final List<double?> values, secondary, simulated;
  final int? hovered;
  _TrendPainter(
    this.values, {
    required this.secondary,
    required this.simulated,
    required this.hovered,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(42, 14, size.width - 12, size.height - 14);
    final maximum = math.max(
      1.0,
      [
        ...values,
        ...secondary,
        ...simulated,
      ].whereType<double>().fold<double>(0, math.max),
    );
    for (var i = 0; i < 4; i++) {
      final y = plot.bottom - plot.height * i / 3;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = const Color(0xFF29343E)
          ..strokeWidth = 1,
      );
      final value = maximum * i / 3;
      final text = TextPainter(
        text: TextSpan(
          text: value >= 1000
              ? '${(value / 1000).toStringAsFixed(1)}k'
              : value.toStringAsFixed(value < 10 ? 1 : 0),
          style: const TextStyle(
            color: muted,
            fontSize: 10,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(0, y - text.height / 2));
    }
    double x(int index) => values.length <= 1
        ? plot.center.dx
        : plot.left + plot.width * index / (values.length - 1);
    void line(List<double?> points, Color color) {
      final path = Path();
      var started = false;
      for (var i = 0; i < points.length; i++) {
        final value = points[i];
        if (value == null) {
          started = false;
          continue;
        }
        final point = Offset(x(i), plot.bottom - plot.height * value / maximum);
        if (!started) {
          path.moveTo(point.dx, point.dy);
          started = true;
        } else {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawCircle(point, 2.4, Paint()..color = color);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke,
      );
    }

    line(values, mint);
    line(secondary, Colors.deepOrangeAccent);
    line(simulated, Colors.lightBlueAccent);
    if (hovered != null && hovered! < values.length) {
      canvas.drawLine(
        Offset(x(hovered!), plot.top),
        Offset(x(hovered!), plot.bottom),
        Paint()
          ..color = Colors.white38
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}
