import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

/// Keeps the field name discoverable while making its requirement visible and audible.
class RequiredLabel extends StatelessWidget {
  final String text;
  const RequiredLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
      Semantics(
        label: AppStrings.of(context).t('requiredField'),
        child: ExcludeSemantics(
          child: Text(
            ' *',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    ],
  );
}

class RequiredFieldsNotice extends StatelessWidget {
  const RequiredFieldsNotice({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(
      AppStrings.of(context).t('requiredFieldsNotice'),
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

EdgeInsets formDialogInsets(BuildContext context) => EdgeInsets.symmetric(
  horizontal: MediaQuery.sizeOf(context).width < 600 ? 12 : 40,
  vertical: 16,
);
