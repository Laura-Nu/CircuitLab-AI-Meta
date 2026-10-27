import 'package:flutter/material.dart';
import '../core/networking/api.dart';
import '../l10n/app_strings.dart';

class OperationsPanel extends StatefulWidget {
  final CircuitApi api;
  final Map<String, dynamic> status;
  const OperationsPanel({super.key, required this.api, required this.status});
  @override
  State<OperationsPanel> createState() => _OperationsPanelState();
}

class _OperationsPanelState extends State<OperationsPanel> {
  List<dynamic>? receipts;
  bool busy = false;
  String? error;
  Future<void> load([String? id]) async {
    if (busy || !widget.api.isAdmin) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (id != null) {
        await widget.api.request(
          '/admin/email-deliveries/$id/refresh',
          method: 'POST',
        );
      }
      final result = await widget.api.request('/admin/email-deliveries');
      if (mounted) setState(() => receipts = result['items'] as List);
    } catch (e) {
      if (mounted) {
        setState(() => error = errorMessage(e, language: widget.api.language));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.api.isAdmin) return const SizedBox.shrink();
    final strings = AppStrings.of(context);
    String tr(String key, [Map<String, Object?> args = const {}]) =>
        strings.t(key, args);
    final worker = widget.status['worker'] as Map? ?? {};
    final queue = widget.status['queue'] as Map? ?? {};
    final budget = widget.status['budget'] as Map? ?? {};
    final emails = (widget.status['email'] as Map?)?['last_24h'] as Map? ?? {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('operationsTitle'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                worker['healthy'] == true
                    ? 'workerHealthy'
                    : 'workerUnavailable',
              ),
              style: TextStyle(
                color: worker['healthy'] == true
                    ? Colors.tealAccent
                    : Colors.amber,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr('operationsQueue', {
                'age': queue['oldest_pending_seconds'] ?? 0,
                'expired': queue['expired_leases'] ?? 0,
              }),
            ),
            Text(
              tr('operationsBudget', {
                'used': budget['used_attempts'] ?? 0,
                'limit': budget['global_limit'] ?? 0,
                'user': budget['per_user_limit'] ?? 0,
              }),
            ),
            const SizedBox(height: 12),
            Text(tr('emailDeliveryNotice')),
            if (((widget.status['email'] as Map?)?['stale_pending'] as num? ??
                    0) >
                0)
              Text(
                tr('emailDispatchStale'),
                style: const TextStyle(color: Colors.amber),
              ),
            for (final entry in emails.entries)
              Text(
                '${strings.label('emailStatus_${entry.key}')}: ${entry.value}',
              ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: busy ? null : () => load(),
              child: Text(tr('viewEmailReceipts')),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.amber)),
            if (receipts != null && receipts!.isEmpty)
              Text(tr('metricsNoData')),
            for (final row in receipts ?? [])
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(strings.label('emailStatus_${row['status']}')),
                    Text(
                      row['id'].toString(),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (row['can_refresh'] == true)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => load(row['id'].toString()),
                        child: Text(tr('refreshEmailStatus')),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
