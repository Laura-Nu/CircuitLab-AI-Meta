import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

class FunctionalCheckDialog extends StatefulWidget {
  final String criteria;
  final bool baseline;
  const FunctionalCheckDialog({
    super.key,
    required this.criteria,
    this.baseline = false,
  });
  @override
  State<FunctionalCheckDialog> createState() => _FunctionalCheckDialogState();
}

class _FunctionalCheckDialogState extends State<FunctionalCheckDialog> {
  final observations = TextEditingController();
  bool? passed;
  bool confirmed = false;
  @override
  void dispose() {
    observations.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    String tr(String key) => strings.t(key);
    final ready =
        confirmed && passed != null && observations.text.trim().length >= 5;
    return AlertDialog(
      title: Text(tr('recordFunctionalTest')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  widget.baseline
                      ? 'baselineFunctionalNotice'
                      : 'functionalTestNotice',
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(widget.criteria),
              const SizedBox(height: 16),
              DropdownButtonFormField<bool>(
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: tr('functionalTestResult'),
                ),
                items: [
                  DropdownMenuItem(
                    value: true,
                    child: Text(tr('functionalTestPassed')),
                  ),
                  DropdownMenuItem(
                    value: false,
                    child: Text(tr('functionalTestFailed')),
                  ),
                ],
                onChanged: (value) => setState(() => passed = value),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: observations,
                maxLines: 4,
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: tr('functionalTestObservations'),
                ),
                onChanged: (_) => setState(() {}),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                title: Text(
                  tr(
                    widget.baseline
                        ? 'baselineFunctionalConfirmed'
                        : 'functionalTestConfirmed',
                  ),
                ),
                onChanged: (value) => setState(() => confirmed = value == true),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('cancel')),
        ),
        FilledButton(
          onPressed: ready
              ? () => Navigator.pop(context, {
                  'passed': passed,
                  'observations': observations.text.trim(),
                })
              : null,
          child: Text(tr('saveFunctionalTest')),
        ),
      ],
    );
  }
}
