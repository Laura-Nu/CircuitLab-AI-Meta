import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

class PasswordVisibilityButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;
  const PasswordVisibilityButton({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: AppStrings.of(
      context,
    ).t(visible ? 'hidePassword' : 'showPassword'),
    isSelected: visible,
    icon: const Icon(Icons.visibility_outlined, size: 20),
    selectedIcon: const Icon(Icons.visibility_off_outlined, size: 20),
    onPressed: onPressed,
  );
}
