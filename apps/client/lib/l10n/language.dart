import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_strings.dart';
import 'document_language.dart';

final languageProvider = StateNotifierProvider<LanguageController, Locale>(
  (ref) => LanguageController(),
);

class LanguageController extends StateNotifier<Locale> {
  bool _chosen = false;
  factory LanguageController({String? requestedLanguage}) =>
      LanguageController._(requestedLanguage ?? takeRequestedLanguage());
  LanguageController._(String? requestedLanguage)
    : super(
        Locale(
          const ['es', 'en'].contains(requestedLanguage)
              ? requestedLanguage!
              : WidgetsBinding
                        .instance
                        .platformDispatcher
                        .locale
                        .languageCode ==
                    'en'
              ? 'en'
              : 'es',
        ),
      ) {
    if (const ['es', 'en'].contains(requestedLanguage)) {
      select(requestedLanguage!);
    } else {
      restore();
    }
  }
  Future<void> restore() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        'circuitlab.language',
      );
      if (mounted && !_chosen && const ['en', 'es'].contains(saved)) {
        state = Locale(saved!);
        saveLandingLanguage(saved);
      }
    } catch (_) {
      /* A storage failure must not prevent using the language selector. */
    }
  }

  Future<void> select(String language) async {
    if (!const ['en', 'es'].contains(language)) return;
    _chosen = true;
    state = Locale(language);
    saveLandingLanguage(language);
    try {
      await (await SharedPreferences.getInstance()).setString(
        'circuitlab.language',
        language,
      );
    } catch (_) {
      /* Keep the in-memory selection if persistence is unavailable. */
    }
  }
}

class LanguageSelector extends ConsumerWidget {
  const LanguageSelector({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageProvider).languageCode;
    return PopupMenuButton<String>(
      tooltip: AppStrings.of(context).t('language'),
      onSelected: (value) => ref.read(languageProvider.notifier).select(value),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          key: const ValueKey('language-es'),
          value: 'es',
          checked: language == 'es',
          child: const Text('Español'),
        ),
        CheckedPopupMenuItem(
          key: const ValueKey('language-en'),
          value: 'en',
          checked: language == 'en',
          child: const Text('English'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 18),
            const SizedBox(width: 6),
            Text(language.toUpperCase(), style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
