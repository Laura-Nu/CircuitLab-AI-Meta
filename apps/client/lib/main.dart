import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_strings.dart';
import 'l10n/language.dart';
import 'l10n/document_language.dart';
import 'core/networking/api.dart';
import 'features/workbench.dart';
import 'features/accounts.dart';
import 'core/session_activity.dart';

final apiProvider = Provider((ref) => CircuitApi());
const mint = Color(0xFF6CE5BC);
const panel = Color(0xFF151C23);
const muted = Color(0xFF91A2AE);

void main() => runApp(const ProviderScope(child: CircuitLabApp()));

class CircuitLabApp extends ConsumerStatefulWidget {
  const CircuitLabApp({super.key});
  @override
  ConsumerState<CircuitLabApp> createState() => _CircuitLabAppState();
}

class _CircuitLabAppState extends ConsumerState<CircuitLabApp> {
  late final router = GoRouter(
    routes: [
      GoRoute(
        path: '/register',
        builder: (_, state) => const Workbench(registering: true),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (_, state) => const RecoveryPage(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (_, state) => RecoveryPage(
          token: state.uri.queryParameters['token'],
          resetting: true,
        ),
      ),
      GoRoute(
        path: '/',
        builder: (_, state) =>
            Workbench(sessionId: state.uri.queryParameters['session']),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(languageProvider);
    ref.read(apiProvider).language = locale.languageCode;
    updateDocumentLanguage(locale.languageCode);
    return MaterialApp.router(
      title: 'CircuitLab AI',
      builder: (context, child) => SessionActivity(
        api: ref.read(apiProvider),
        child: SafeArea(child: child ?? const SizedBox()),
      ),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      locale: locale,
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        AppStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1319),
        colorScheme: const ColorScheme.dark(
          primary: mint,
          surface: panel,
          secondary: mint,
        ),
        fontFamily: 'Roboto',
        dividerColor: const Color(0xFF29343E),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 14, height: 1.5),
          headlineLarge: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.2,
          ),
          headlineSmall: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -.5,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          errorMaxLines: 3,
          filled: true,
          fillColor: const Color(0xFF0F161D),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF34424C)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF34424C)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
            textStyle: const TextStyle(
              fontFamily: 'Roboto',
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
