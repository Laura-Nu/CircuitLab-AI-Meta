import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../core/networking/api.dart';
import '../main.dart';
import '../l10n/app_strings.dart';
import '../core/form_fields.dart';
import '../core/measurement_points.dart';
import '../core/browser_usb.dart';
import '../l10n/language.dart';
import 'accounts.dart';
import 'account_identity.dart';
import 'investigation.dart';
import 'metrics.dart';
import 'functional_check.dart';
import 'specification_dialog.dart';
import 'bridge_setup.dart';
import 'session_guidance.dart';
import 'session_results.dart';
import 'hardware_point_field.dart';
import 'serial_monitor.dart';
import '../core/number_format.dart';
import '../core/brand.dart';
import '../core/password_visibility.dart';

class Workbench extends ConsumerStatefulWidget {
  final String? sessionId;
  final bool registering;
  const Workbench({super.key, this.sessionId, this.registering = false});
  @override
  ConsumerState<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends ConsumerState<Workbench>
    with WidgetsBindingObserver {
  String tr(String key, [Map<String, Object?> args = const {}]) =>
      AppStrings.of(context).t(key, args);
  dynamic localized(Map data, String field) =>
      (data['translations'] as Map?)?[api.language]?[field] ?? data[field];
  Map<String, String> get families => {
    'microcontroller': tr('microcontrollerProject'),
    'custom': tr('customProject'),
    'led_resistor': tr('ledResistor'),
    'voltage_divider': tr('voltageDivider'),
    'analog_sensor': tr('analogSensor'),
    'digital_signal': tr('digitalSignal'),
  };
  Map<String, String> get states => {
    'draft': tr('draft'),
    'ready': tr('readyToAnalyze'),
    'analyzing': tr('analyzing'),
    'awaiting_evidence': tr('evidenceNeeded'),
    'awaiting_confirmation': tr('confirmAConnection'),
    'awaiting_measurement': tr('measurementPending'),
    'awaiting_intervention': tr('humanIntervention'),
    'verifying': tr('verifying'),
    'awaiting_functional_check': tr('baselineCheckNeeded'),
    'no_fault_found': tr('finishedNoFault'),
    'resolved': tr('finishedVerified'),
    'inconclusive': tr('finishedInconclusive'),
    'cancelled': tr('finishedWithoutVerification'),
  };

  late final CircuitApi api;
  late final BrowserUsbController usb;
  final mail = TextEditingController();
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  final search = TextEditingController();
  List<dynamic> sessions = [], devices = [], events = [];
  Map<String, dynamic>? selected;
  String mode = '', section = 'sessions', sessionFilter = 'all';
  bool providerConfigured = false, simulationAllowed = false;
  bool passwordVisible = false, confirmationVisible = false;
  String? error;
  bool busy = false, restoring = true, refreshing = false;
  bool analysisRequested = false;
  int pending = 0;
  Timer? timer;
  bool? efficientEndpoints;
  DateTime? lastWorkspaceSync;
  bool refreshAgain = false, foreground = true;

  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api = ref.read(apiProvider);
    api.addListener(authChanged);
    usb = ref.read(browserUsbProvider);
    usb.addListener(usbChanged);
    init();
    timer = Timer.periodic(Duration(seconds: 4), (_) {
      if (foreground && api.signedIn && !busy && !refreshing) {
        refresh(silent: true);
      }
    });
  }

  void usbChanged() {
    if (mounted) setState(() {});
  }

  void authChanged() {
    if (!mounted) return;
    setState(() {
      if (!api.signedIn) {
        selected = null;
        sessions = [];
        devices = [];
        events = [];
        section = 'sessions';
      }
    });
  }

  Future<void> init() async {
    await api.restore();
    if (!mounted) return;
    setState(() => restoring = false);
    if (api.signedIn) await refresh();
  }

  @override
  void didUpdateWidget(covariant Workbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId && api.signedIn) refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && api.signedIn) {
      lastWorkspaceSync = null;
      refresh(silent: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    api.removeListener(authChanged);
    usb.removeListener(usbChanged);
    confirmPassword.dispose();
    mail.dispose();
    password.dispose();
    search.dispose();
    super.dispose();
  }

  void toast(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> action(Future<void> Function() call) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await call();
      if (api.signedIn) await refresh();
    } catch (e) {
      if (mounted) {
        setState(() => error = errorMessage(e, language: api.language));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<Map<String, dynamic>> loadWorkspace() async {
    if (efficientEndpoints != false) {
      try {
        final data = await api.request('/workspace');
        if (data is Map && data['sessions'] is List && data['health'] is Map) {
          efficientEndpoints = true;
          return Map<String, dynamic>.from(data);
        }
        efficientEndpoints = false;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
        efficientEndpoints = false;
      }
    }
    // Compatibility with an older backend, including the existing test adapters.
    final values = await Future.wait<dynamic>([
      api.request('/sessions'),
      api.request('/auth/me'),
      api.request('/devices'),
      api.dio.get('/health/live').then((r) => r.data),
    ]);
    return {
      'sessions': values[0],
      'account': values[1],
      'devices': values[2],
      'health': values[3],
    };
  }

  Future<void> refresh({bool silent = false}) async {
    if (refreshing) {
      if (!silent) refreshAgain = true;
      return;
    }
    refreshing = true;
    final wanted = section == 'sessions' ? widget.sessionId : null;
    try {
      final queue = await api.outbox.pending(api.scope);
      if (queue.isNotEmpty) await api.sync();
      final overviewActive = sessions.any((row) => row['state'] == 'analyzing');
      final metadataAge = section == 'devices'
          ? 8
          : wanted == null
          ? (overviewActive ? 4 : 15)
          : 30;
      final needWorkspace =
          efficientEndpoints != true ||
          !silent ||
          queue.isNotEmpty ||
          lastWorkspaceSync == null ||
          DateTime.now().difference(lastWorkspaceSync!).inSeconds >=
              metadataAge;
      final metadataFuture = needWorkspace ? loadWorkspace() : null;
      final old = selected?['id'] == wanted ? selected : null;
      final active = (old?['jobs'] as List? ?? []).any(
        (j) => ['pending', 'running'].contains(j['status']),
      );
      final needDetail =
          wanted != null &&
          (!silent ||
              old == null ||
              !sessionFinished(old['state']) ||
              active ||
              needWorkspace);
      final resetHistory = !silent || old == null;
      final known = resetHistory ? 0 : old['version'] ?? 0;
      final after = resetHistory || events.isEmpty
          ? 0
          : events.last['sequence'] ?? 0;
      Future<dynamic>? progressFuture;
      if (needDetail && efficientEndpoints == true) {
        progressFuture = api.request(
          '/sessions/$wanted/progress?known_version=$known&after=$after',
        );
      }
      final fetched = await Future.wait<dynamic>([
        metadataFuture ?? Future<dynamic>.value(null),
        progressFuture ?? Future<dynamic>.value(null),
      ]);
      final metadata = fetched[0];
      if (metadata != null) lastWorkspaceSync = DateTime.now();
      Map<String, dynamic>? detail = old;
      List<dynamic> history = old == null ? [] : events;
      if (needDetail) {
        if (efficientEndpoints == true) {
          final progress =
              await (progressFuture != null
                      ? Future<dynamic>.value(fetched[1])
                      : api.request(
                          '/sessions/$wanted/progress?known_version=$known&after=$after',
                        ))
                  as Map;
          if (progress['snapshot'] is Map) {
            detail = Map<String, dynamic>.from(progress['snapshot']);
          } else if (detail != null) {
            detail = Map<String, dynamic>.from(detail);
          }
          if (detail != null) {
            detail['jobs'] = progress['jobs'];
            detail['analysis_phase'] = progress['analysis_phase'];
          }
          final incoming = progress['events'] as List? ?? [];
          final merged = <dynamic, dynamic>{};
          if (!resetHistory) {
            for (final event in history) {
              merged[event['sequence']] = event;
            }
          }
          for (final event in incoming) {
            merged[event['sequence']] = event;
          }
          history = merged.values.toList()
            ..sort((a, b) => (a['sequence'] as num).compareTo(b['sequence']));
        } else {
          final values = await Future.wait<dynamic>([
            api.request('/sessions/$wanted'),
            api.request('/sessions/$wanted/events'),
          ]);
          detail = Map<String, dynamic>.from(values[0]);
          history = values[1] as List;
        }
      }
      if (!mounted || !api.signedIn) return;
      // A slow response from the previous route must never replace the new circuit.
      if (wanted != (section == 'sessions' ? widget.sessionId : null)) {
        refreshAgain = true;
        return;
      }
      setState(() {
        if (metadata != null) {
          sessions = metadata['sessions'] as List;
          devices = metadata['devices'] as List;
          final account = metadata['account'];
          if (account is Map) api.account = Map<String, dynamic>.from(account);
          final health = metadata['health'] as Map;
          mode = health['ai_mode'];
          providerConfigured = health['provider_configured'] == true;
          simulationAllowed = health['simulation_allowed'] == true;
        }
        selected = wanted == null ? null : detail;
        events = wanted == null ? [] : history;
        if (detail != null) {
          sessions = [
            for (final row in sessions)
              if (row['id'] == detail['id'])
                {
                  ...row as Map,
                  'state': detail['state'],
                  'version': detail['version'],
                }
              else
                row,
          ];
        }
        pending = 0;
        if (!silent) error = null;
      });
    } catch (e) {
      if (mounted && (!silent || !api.signedIn)) {
        setState(() => error = errorMessage(e, language: api.language));
      }
    } finally {
      refreshing = false;
      if (refreshAgain && mounted && api.signedIn) {
        refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (restoring) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!api.signedIn) return login();
    final wide = MediaQuery.sizeOf(context).width > 1000;
    return Scaffold(
      key: scaffoldKey,
      drawer: wide ? null : Drawer(child: sidebar()),
      body: Row(
        children: [
          if (wide) SizedBox(width: 238, child: sidebar()),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 76,
                  padding: EdgeInsets.symmetric(horizontal: wide ? 36 : 16),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF25303A)),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (!wide)
                        Builder(
                          builder: (c) => IconButton(
                            onPressed: () => Scaffold.of(c).openDrawer(),
                            icon: Icon(Icons.menu),
                          ),
                        ),
                      if (wide)
                        Text(
                          tr('workspace'),
                          style: TextStyle(
                            color: muted,
                            fontSize: 11,
                            letterSpacing: 1.7,
                          ),
                        ),
                      Spacer(),
                      LanguageSelector(),
                      if (mode.isNotEmpty &&
                          (api.isAdmin || mode == 'simulation') &&
                          MediaQuery.sizeOf(context).width >= 680)
                        badge(
                          mode == 'simulation'
                              ? tr('simulation')
                              : providerConfigured
                              ? tr('metaConfigured')
                              : tr('metaNotConfigured'),
                          mode == 'simulation' || !providerConfigured
                              ? Colors.amber
                              : mint,
                        ),
                      if (!kIsWeb) ...[
                        SizedBox(width: wide ? 16 : 4),
                        IconButton(
                          tooltip: tr('sync'),
                          onPressed: busy
                              ? null
                              : () => action(() => api.sync().then((_) {})),
                          icon: Icon(Icons.sync, size: 20),
                        ),
                        AccountIdentity(
                          email: api.email,
                          compact:
                              MediaQuery.sizeOf(context).width < 680 ||
                              (api.isAdmin &&
                                  wide &&
                                  MediaQuery.sizeOf(context).width < 1200),
                        ),
                      ],
                    ],
                  ),
                ),
                if (busy) LinearProgressIndicator(minHeight: 2),
                if (usb.active || usb.connecting)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        if (usb.connecting || usb.state == 'reading')
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.usb, size: 18, color: mint),
                        const SizedBox(width: 10),
                        Expanded(child: Text(usbStatus())),
                        TextButton(
                          onPressed: () => usb.disconnect(),
                          child: Text(tr('usbDisconnect')),
                        ),
                      ],
                    ),
                  ),
                if (error != null)
                  Container(
                    width: double.infinity,
                    color: Color(0xFF412B24),
                    padding: EdgeInsets.all(14),
                    child: Text(
                      error!,
                      style: TextStyle(color: Color(0xFFFFCBA4)),
                    ),
                  ),
                if (pending > 0)
                  MaterialBanner(
                    content: Text(tr('pendingSync', {'count': pending})),
                    actions: [
                      TextButton(
                        onPressed: () => action(() async {
                          await api.sync();
                        }),
                        child: Text(tr('retry')),
                      ),
                    ],
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(wide ? 36 : 20),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: 1350),
                        child: section == 'metrics' && api.isAdmin
                            ? MetricsPanel(api: api)
                            : section == 'users' && api.isAdmin
                            ? AccountsPanel(api: api)
                            : section == 'devices'
                            ? devicePage()
                            : selected == null
                            ? dashboard()
                            : sessionPage(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget sidebar() => Container(
    color: Color(0xFF10171E),
    child: SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 0, 22, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 76,
              child: Align(alignment: Alignment.centerLeft, child: brand()),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 28),
                    Text(
                      tr('laboratory'),
                      style: TextStyle(
                        color: muted,
                        fontSize: 10,
                        letterSpacing: 2,
                      ),
                    ),
                    SizedBox(height: 14),
                    nav(Icons.grid_view_rounded, tr('mySessions'), 'sessions'),
                    nav(Icons.usb_rounded, tr('devices'), 'devices'),
                    if (api.isAdmin) ...[
                      nav(Icons.insights_outlined, tr('metricsNav'), 'metrics'),
                      nav(Icons.manage_accounts_outlined, tr('users'), 'users'),
                    ],
                  ],
                ),
              ),
            ),
            if (kIsWeb) ...[
              AccountIdentity(email: api.email, sidebar: true),
              SizedBox(height: 8),
            ],
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      await api.logout();
                      selected = null;
                    }),
              icon: Icon(Icons.logout, size: 16),
              label: Text(tr('signOut'), style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    ),
  );
  Widget nav(IconData icon, String label, String id) => Padding(
    padding: EdgeInsets.only(bottom: 6),
    child: ListTile(
      dense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: section == id,
      selectedColor: mint,
      selectedTileColor: mint.withValues(alpha: .08),
      leading: Icon(icon, size: 19),
      title: Text(label, style: TextStyle(fontSize: 13)),
      onTap: () {
        setState(() => section = id);
        refresh();
        if (id == 'sessions') context.go('/');
        scaffoldKey.currentState?.closeDrawer();
      },
    ),
  );
  Widget brand() =>
      CircuitBrand(language: api.language, tooltip: tr('backToLanding'));

  Widget login() => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1080),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 90,
            runSpacing: 24,
            children: [
              SizedBox(
                width: math.min(440, MediaQuery.sizeOf(context).width - 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: brand()),
                        LanguageSelector(),
                      ],
                    ),
                    if (MediaQuery.sizeOf(context).width >= 760) ...[
                      SizedBox(height: 50),
                      badge(tr('fromSymptomsToEvidence'), mint),
                      SizedBox(height: 24),
                      Text(
                        tr('understandTheFaultVerifyTheSolution'),
                        style: TextStyle(
                          fontSize: 52,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -2,
                        ),
                      ),
                      SizedBox(height: 22),
                      Text(
                        tr(
                          'electronicDiagnosisGuidedByHypothesesMeasurementsAndVerifiable',
                        ),
                        style: TextStyle(
                          color: muted,
                          fontSize: 16,
                          height: 1.7,
                        ),
                      ),
                      SizedBox(height: 26),
                      SizedBox(
                        height: 140,
                        width: 400,
                        child: CustomPaint(painter: CircuitPainter()),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(
                width: math.min(370, MediaQuery.sizeOf(context).width - 48),
                child: box(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        tr(
                          widget.registering
                              ? 'createMemberAccount'
                              : 'welcomeToYourLaboratory',
                        ),
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        tr(
                          widget.registering
                              ? 'memberSignupDescription'
                              : 'signInWithYourLaboratoryAccount',
                        ),
                        style: TextStyle(color: muted),
                      ),
                      SizedBox(height: 24),
                      const RequiredFieldsNotice(),
                      TextField(
                        controller: mail,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          label: RequiredLabel(tr('emailAddress')),
                          prefixIcon: Icon(Icons.alternate_email, size: 18),
                        ),
                      ),
                      SizedBox(height: 18),
                      TextField(
                        controller: password,
                        obscureText: !passwordVisible,
                        decoration: InputDecoration(
                          label: RequiredLabel(tr('password')),
                          suffixIcon: PasswordVisibilityButton(
                            visible: passwordVisible,
                            onPressed: () => setState(
                              () => passwordVisible = !passwordVisible,
                            ),
                          ),
                          prefixIcon: Icon(Icons.lock_outline, size: 18),
                        ),
                        onSubmitted: (_) => signIn(),
                      ),
                      if (widget.registering) ...[
                        SizedBox(height: 18),
                        TextField(
                          controller: confirmPassword,
                          obscureText: !confirmationVisible,
                          decoration: InputDecoration(
                            label: RequiredLabel(tr('confirmPassword')),
                            suffixIcon: PasswordVisibilityButton(
                              visible: confirmationVisible,
                              onPressed: () => setState(
                                () =>
                                    confirmationVisible = !confirmationVisible,
                              ),
                            ),
                            prefixIcon: Icon(Icons.lock_outline, size: 18),
                          ),
                          onSubmitted: (_) => signIn(),
                        ),
                        SizedBox(height: 10),
                        Text(
                          tr('passwordMinimum'),
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                      SizedBox(height: 24),
                      if (api.sessionExpired)
                        Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text(
                            tr('sessionExpiredIdle'),
                            style: TextStyle(color: Colors.amber),
                          ),
                        ),
                      if (error != null)
                        Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text(
                            error!,
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                      FilledButton(
                        onPressed: busy ? null : signIn,
                        child: Text(
                          busy
                              ? tr('connecting')
                              : tr(
                                  widget.registering
                                      ? 'createAccount'
                                      : 'enterTheLaboratory',
                                ),
                        ),
                      ),
                      SizedBox(height: 12),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () {
                                setState(() => error = null);
                                context.go(
                                  widget.registering ? '/' : '/register',
                                );
                              },
                        child: Text(
                          tr(
                            widget.registering
                                ? 'alreadyHaveAccount'
                                : 'createAccountLink',
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => launchDownload(),
                        icon: Icon(Icons.android),
                        label: Text(tr('downloadAndroid')),
                      ),
                      SizedBox(height: 8),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => context.go('/forgot-password'),
                        child: Text(tr('forgotPassword')),
                      ),
                      Text(
                        tr('05VCircuitsAndroidAndWebAccounts'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          height: 1.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> launchDownload() async {
    final url = landingUri(api.language).replace(fragment: 'download');
    await openPublicUrl(url);
  }

  void signIn() => action(() async {
    if (widget.registering) {
      if (password.text.length < 12) {
        throw Exception(tr('passwordMinimum'));
      }
      if (password.text != confirmPassword.text) {
        throw Exception(tr('passwordsMustMatch'));
      }
      await api.register(mail.text.trim(), password.text);
      if (mounted) context.go('/');
    } else {
      await api.login(mail.text.trim(), password.text);
    }
    password.clear();
    confirmPassword.clear();
    passwordVisible = false;
    confirmationVisible = false;
  });

  Widget dashboard() {
    final query = search.text.toLowerCase();
    final filtered = sessions
        .where(
          (s) => '${s['title']} ${families[s['family']]}'
              .toLowerCase()
              .contains(query),
        )
        .where(
          (s) => switch (sessionFilter) {
            'action' =>
              !sessionFinished(s['state']) && s['state'] != 'analyzing',
            'analyzing' => s['state'] == 'analyzing',
            'finished' => sessionFinished(s['state']),
            _ => true,
          },
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 28,
          runSpacing: 16,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('yourConnectedLaboratory'),
                  style: TextStyle(fontSize: 11, color: mint, letterSpacing: 1),
                ),
                SizedBox(height: 8),
                Text(
                  tr('diagnosticSessions'),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                SizedBox(height: 8),
                Text(
                  tr('observeTestAndVerifyEveryRepair'),
                  style: TextStyle(color: muted),
                ),
              ],
            ),
            FilledButton.icon(
              onPressed: busy ? null : createSession,
              icon: Icon(Icons.add, size: 19),
              label: Text(tr('newSession')),
            ),
          ],
        ),
        SizedBox(height: 30),
        LayoutBuilder(
          builder: (_, c) => Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              stat(
                tr('sessions'),
                '${sessions.length}',
                Icons.folder_open,
                tr('yourLaboratoryHistory'),
                c.maxWidth,
              ),
              stat(
                tr('inProgress'),
                '${sessions.where((s) => !sessionFinished(s['state'])).length}',
                Icons.hub_outlined,
                tr('openDiagnoses'),
                c.maxWidth,
              ),
              stat(
                tr('finishedInvestigations'),
                '${sessions.where((s) => sessionFinished(s['state'])).length}',
                Icons.task_alt,
                tr('checkDataSourcesInTheReport'),
                c.maxWidth,
              ),
            ],
          ),
        ),
        SizedBox(height: 30),
        box(
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    badge(tr('evidenceBeforeConclusions'), mint),
                    SizedBox(height: 14),
                    Text(
                      tr('everyTestHasAPurpose'),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      tr('defineTheExpectedResultAndConfirmTheSchematic'),
                      style: TextStyle(color: muted, height: 1.7),
                    ),
                  ],
                ),
              ),
              if (MediaQuery.sizeOf(context).width > 800)
                SizedBox(
                  width: 280,
                  height: 140,
                  child: CustomPaint(painter: CircuitPainter()),
                ),
            ],
          ),
        ),
        SizedBox(height: 32),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              tr('recentSessions'),
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: redeem,
              icon: Icon(Icons.link, size: 17),
              label: Text(tr('openInvitation')),
            ),
          ],
        ),
        SizedBox(height: 16),
        TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: tr('searchByNameOrCircuitFamily'),
            prefixIcon: Icon(Icons.search, size: 20),
          ),
        ),
        SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final filter in {
              'all': 'filterAll',
              'action': 'filterAction',
              'analyzing': 'filterAnalyzing',
              'finished': 'filterFinished',
            }.entries)
              ChoiceChip(
                label: Text(tr(filter.value)),
                selected: sessionFilter == filter.key,
                onSelected: (_) => setState(() => sessionFilter = filter.key),
              ),
          ],
        ),
        SizedBox(height: 16),
        if (filtered.isEmpty)
          box(
            Column(
              children: [
                SizedBox(height: 18),
                Icon(Icons.memory_outlined, color: muted, size: 42),
                SizedBox(height: 18),
                Text(
                  query.isEmpty
                      ? tr('yourNextInvestigationStartsHere')
                      : tr('noMatches'),
                  style: TextStyle(fontSize: 18),
                ),
                SizedBox(height: 8),
                Text(
                  tr('createASessionAndRecordTheCircuitBehavior'),
                  style: TextStyle(color: muted),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 20),
                TextButton(
                  onPressed: createSession,
                  child: Text(tr('createYourFirstSession')),
                ),
              ],
            ),
          )
        else
          for (final s in filtered) sessionCard(Map<String, dynamic>.from(s)),
        SizedBox(height: 24),
        Text(
          tr('circuitlabAiTraceableDiagnosis'),
          style: TextStyle(color: muted, letterSpacing: 1.2, fontSize: 10),
        ),
      ],
    );
  }

  Widget sessionCard(Map<String, dynamic> s) => Padding(
    padding: EdgeInsets.only(bottom: 12),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.go('/?session=${s['id']}'),
      child: box(
        LayoutBuilder(
          builder: (_, constraints) {
            final tone = sessionTone(s['state']);
            final status = badge(tr(sessionTitleKey(s['state'])), tone);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: .09),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        sessionIcon(s['state']),
                        color: tone,
                        size: 24,
                      ),
                    ),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s['title'],
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            '${families[s['family']]} · ${AppStrings.of(context).number(s['supply_v'] as num)} V',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (constraints.maxWidth > 720) ...[
                      SizedBox(width: 12),
                      status,
                    ],
                  ],
                ),
                SizedBox(height: 12),
                if (constraints.maxWidth <= 720) ...[
                  status,
                  SizedBox(height: 10),
                ],
                Text(
                  tr(sessionSummaryKey(s['state'])),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 13),
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      tr(
                        sessionFinished(s['state'])
                            ? 'viewOutcome'
                            : 'continueInvestigation',
                      ),
                      style: TextStyle(
                        color: tone,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(width: 8),
                    Icon(Icons.arrow_forward, color: tone, size: 17),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget stat(
    String label,
    String value,
    IconData icon,
    String subtitle,
    double width,
  ) => SizedBox(
    width: width > 850
        ? (width - 32) / 3
        : width > 500
        ? (width - 16) / 2
        : width,
    child: box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: muted,
                    fontSize: 10,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              SizedBox(width: 8),
              Icon(icon, color: mint, size: 19),
            ],
          ),
          SizedBox(height: 16),
          Text(
            value,
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(subtitle, style: TextStyle(color: muted, fontSize: 11)),
        ],
      ),
    ),
  );

  Widget sessionPage() {
    final s = selected!;
    final state = s['state'];
    final editable = s['can_edit'] == true;
    final plan = s['pending_test'] as Map?;
    final measurements = s['measurements'] as List;
    final analysisJobs = (s['jobs'] as List? ?? [])
        .where(
          (job) =>
              job['kind'] == 'analysis' &&
              ['pending', 'running'].contains(job['status']),
        )
        .toList();
    final currentJob = analysisJobs.isEmpty ? null : analysisJobs.last;
    final analyzing =
        analysisRequested || state == 'analyzing' || currentJob != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => context.go('/'),
          icon: Icon(Icons.arrow_back, size: 16),
          label: Text(tr('allSessions')),
        ),
        SizedBox(height: 14),
        Wrap(
          spacing: 16,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(s['title'], style: Theme.of(context).textTheme.headlineLarge),
            badge(states[state] ?? state, sessionTone(state)),
          ],
        ),
        SizedBox(height: 10),
        Text(
          tr('specificationVersion', {
            'family': families[s['family']],
            'voltage': s['supply_v'],
            'version': s['spec_version'],
          }),
          style: TextStyle(color: muted, fontSize: 12),
        ),
        SizedBox(height: 20),
        if (s['evidence_review_required'] == true) ...[
          box(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.amber),
                const SizedBox(width: 12),
                Expanded(child: Text(tr('evidenceReviewRequired'))),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        SessionGuidance(
          session: s,
          busy: busy,
          analyzing: analyzing,
          onSpec: editSpec,
          onEvidence: capture,
          onAnalyze: requestAnalysis,
          onConfirm: confirmConnection,
          onManual: measure,
          onBridge: hardware,
          onIntervention: confirmIntervention,
          onFunctional: recordFunctionalCheck,
          onVerify: () => post('verification'),
          onBaseline: recordBaselineCheck,
          onReport: () => showReport(readable: true),
          onNew: createSession,
        ),
        SizedBox(height: 20),
        SessionResults(
          session: s,
          events: events,
          busy: busy,
          onReport: () => showReport(readable: true),
        ),
        if (editable) ...[
          const SizedBox(height: 16),
          SerialMonitor(
            key: ValueKey('serial-${s['id']}'),
            api: api,
            sessionId: s['id'],
            canSave: !busy && !analyzing && !sessionFinished(state) &&
              !(s['jobs'] as List? ?? []).any((job) => ['pending', 'running'].contains(job['status'])),
            onSaved: () => refresh(),
          ),
        ],
        SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            if (editable && (s['completion'] as Map?)?['can_close'] == true)
              TextButton.icon(
                onPressed: busy ? null : closeInvestigation,
                icon: Icon(Icons.stop_circle_outlined, size: 17),
                label: Text(tr('finishWithoutVerification')),
              ),
            if (editable)
              OutlinedButton.icon(
                onPressed: busy ? null : pair,
                icon: Icon(Icons.devices, size: 17),
                label: Text(tr('shareReview')),
              ),
            if (api.isAdmin)
              OutlinedButton.icon(
                onPressed: showReport,
                icon: Icon(Icons.description_outlined, size: 17),
                label: Text(tr('jsonReport')),
              ),
          ],
        ),
        SizedBox(height: 24),
        Text(
          tr('originalContent'),
          style: TextStyle(color: muted, fontSize: 11),
        ),
        SizedBox(height: 12),
        ExpansionTile(
          key: PageStorageKey('circuit-details-${s['id']}'),
          title: Text(tr('detailsAndEvidence')),
          leading: Icon(Icons.account_tree_outlined),
          initiallyExpanded: ['draft', 'awaiting_evidence'].contains(state),
          tilePadding: EdgeInsets.symmetric(horizontal: 4),
          children: [
            box(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading(Icons.flag_outlined, tr('sessionObjective')),
                  SizedBox(height: 10),
                  Text(
                    tr(
                      s['purpose'] == 'check_operation'
                          ? 'purposeCheckOperation'
                          : 'purposeDiagnosis',
                    ),
                    style: TextStyle(color: mint),
                  ),
                  SizedBox(height: 16),
                  Text(
                    tr('expectedResult'),
                    style: TextStyle(
                      color: mint,
                      fontSize: 10,
                      letterSpacing: 1.2,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(s['expected']),
                  SizedBox(height: 16),
                  Text(
                    tr('observedSymptom'),
                    style: TextStyle(
                      color: muted,
                      fontSize: 10,
                      letterSpacing: 1.2,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    (s['symptoms'] as String? ?? '').isEmpty
                        ? tr('noSymptomsReported')
                        : s['symptoms'],
                  ),
                ],
              ),
            ),
            SizedBox(height: 18),
            box(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: heading(
                          Icons.photo_library_outlined,
                          tr('visualEvidence'),
                        ),
                      ),
                      if (editable &&
                          ![
                            'resolved',
                            'no_fault_found',
                            'awaiting_functional_check',
                            'cancelled',
                            'inconclusive',
                            'analyzing',
                          ].contains(state))
                        IconButton(
                          onPressed: busy ? null : capture,
                          tooltip: tr('attachImage'),
                          icon: Icon(
                            Icons.add_photo_alternate_outlined,
                            color: mint,
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 14),
                  if ((s['evidence'] as List).isEmpty)
                    Text(
                      tr('attachAnOverviewAndCloseUpsHiddenConnections'),
                      style: TextStyle(color: muted),
                    )
                  else
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final e in s['evidence'])
                          SizedBox(
                            key: ValueKey('photo-tile-${e['id']}'),
                            width: 190,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                EvidenceThumbnail(
                                  key: ValueKey('${s['id']}:${e['id']}'),
                                  api: api,
                                  sessionId: s['id'],
                                  evidence: e,
                                ),
                                if (editable)
                                  TextButton.icon(
                                    onPressed: busy || analyzing
                                        ? null
                                        : () => removeEvidence(e),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                    ),
                                    label: Text(tr('removeEvidence')),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            SizedBox(height: 18),
          ],
        ),
        SizedBox(height: 16),
        box(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading(
                Icons.psychology_outlined,
                tr('hypothesesAndObservations'),
              ),
              SizedBox(height: 14),
              if (plan?['observations'] != null)
                for (final o in localized(plan!, 'observations'))
                  Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text('• $o', style: TextStyle(color: muted)),
                  ),
              if ((s['hypotheses'] as List).isEmpty)
                Text(
                  tr('theAnalysisWillAppearHereEveryConclusionMust'),
                  style: TextStyle(color: muted),
                ),
              for (final h
                  in (s['hypotheses'] as List)
                      .where(
                        (h) =>
                            h['data']['analysis_step'] ==
                            (s['analysis_steps'] ?? 0),
                      )
                      .toList()
                      .reversed) ...[
                Divider(),
                Text(
                  localized(h['data'], 'cause'),
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 6),
                Text(
                  tr('hypothesisStep', {
                    'status': AppStrings.of(context).label(h['data']['status']),
                    'step': h['data']['analysis_step'],
                  }),
                  style: TextStyle(color: mint, fontSize: 11),
                ),
                SizedBox(height: 6),
                Text(
                  localized(h['data'], 'explanation'),
                  style: TextStyle(color: muted),
                ),
                if (api.isAdmin)
                  Text(
                    tr('references', {
                      'ids': (h['data']['evidence_ids'] as List).join(', '),
                    }),
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
              ],
            ],
          ),
        ),
        SizedBox(height: 18),
        box(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading(
                Icons.monitor_heart_outlined,
                tr('measurementsAndCriteria'),
              ),
              SizedBox(height: 16),
              for (final p in (s['specification']['points'] ?? []))
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${measurementPointName(s['specification'], p['id'], includeReference: api.isAdmin)} / ${AppStrings.of(context).criterion(p)}',
                    style: TextStyle(color: muted),
                  ),
                ),
              if (measurements.isEmpty)
                Text(
                  tr('noReadingsRecordedYet'),
                  style: TextStyle(color: muted),
                ),
              for (final m in measurements.reversed)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(
                    spacing: 20,
                    runSpacing: 6,
                    children: [
                      Text(
                        measurementPointName(
                          s['specification'],
                          m['point_id'],
                          includeReference: api.isAdmin,
                        ),
                        style: TextStyle(
                          color: mint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        AppStrings.of(
                          context,
                        ).observation(m['value'], m['unit']),
                        style: TextStyle(fontFamily: 'monospace', fontSize: 18),
                      ),
                      badge(
                        AppStrings.of(context).label(m['source']),
                        m['source'] == 'simulated' ? Colors.amber : muted,
                      ),
                      Text(
                        m['phase'] == 'verification'
                            ? tr('afterIntervention')
                            : tr('diagnosis'),
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              for (final v in s['verifications']) ...[
                Divider(),
                Text(
                  v['data']['functional_check'] == null
                      ? tr('legacyVoltageOnly')
                      : v['data']['passed'] == true
                      ? tr('theElectricalCriteriaAreMet')
                      : tr('theFunctionalCriterionIsNotMet'),
                  style: TextStyle(
                    color: v['data']['passed'] == true ? mint : Colors.amber,
                  ),
                ),
                if (v['data']['functional_check'] != null) ...[
                  Text(v['data']['functional_check']['observations'] ?? ''),
                  Text(
                    tr('verificationSource', {
                      'source': AppStrings.of(
                        context,
                      ).label(v['data']['verification_basis'] ?? 'manual'),
                    }),
                    style: TextStyle(color: muted),
                  ),
                ],
                if (v['data']['physical_verification'] != true ||
                    v['data']['functional_check'] == null)
                  Text(
                    tr('thisDoesNotEstablishFullPhysicalVerification'),
                    style: TextStyle(color: Colors.amber),
                  ),
              ],
            ],
          ),
        ),
        SizedBox(height: 18),
        ExpansionTile(
          key: PageStorageKey('session-history-${s['id']}'),
          title: Text(tr('investigationHistory')),
          leading: Icon(Icons.history),
          tilePadding: EdgeInsets.symmetric(horizontal: 4),
          children: [
            box(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading(Icons.history, tr('timeline')),
                  SizedBox(height: 14),
                  for (final e in events.reversed.take(35))
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.circle, color: mint, size: 7),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              eventLabel(e),
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ),
                          Text(
                            '#${e['sequence']}',
                            style: TextStyle(
                              color: muted,
                              fontFamily: 'monospace',
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: 18),
          ],
        ),
        SizedBox(height: 18),
        ExpansionTile(
          title: Text(tr('agentDecisionTrace')),
          tilePadding: EdgeInsets.symmetric(horizontal: 4),
          children: [
            InvestigationPanels(
              session: s,
              busy: busy,
              technicalDetails: api.isAdmin,
              onGenerate: () => post('storyboards'),
            ),
          ],
        ),
      ],
    );
  }

  String eventLabel(dynamic e) =>
      {
        'investigation_closed': tr('investigationClosed'),
        'baseline_assessment_completed': tr('baselineAssessmentCompleted'),
        'baseline_functional_check_recorded': tr('baselineFunctionalRecorded'),
        'evidence_removed': tr('evidenceRemovedEvent'),
        'session_created': tr('sessionCreated'),
        'specification_confirmed': tr('schematicAndCriteriaConfirmed'),
        'evidence_added': tr('imageAttached'),
        'serial_captured': tr('serialCapturedEvent'),
        'connection_confirmed': tr('connectionConfirmed'),
        'measurement_recorded': tr('measurementEvent', {
          'source': AppStrings.of(context).label(e['data']['source'] ?? ''),
        }),
        'intervention_confirmed': tr('humanInterventionConfirmed'),
        'job_queued': tr('analysisQueued'),
        'job_completed': tr('jobCompleted'),
        'story_requested': tr('storyRequested'),
        'story_completed': tr('storyCompleted'),
        'story_failed': tr('storyFailed'),
        'diagnosis_updated': tr('hypothesesUpdated'),
        'verification_completed': tr('functionalCriteriaEvaluated'),
        'functional_check_recorded': tr('recordFunctionalTest'),
        'job_error': tr('analysisError', {
          'error': AppStrings.of(context).label(e['data']['code'] ?? ''),
        }),
        'hardware_failed': tr('readingError', {
          'error': AppStrings.of(context).label(e['data']['status'] ?? ''),
        }),
        'hardware_requested': tr('commandSentToBridge'),
        'hardware_result': tr('bridgeResponse'),
        'state_changed': tr('stateEvent', {
          'state': states[e['data']['to']] ?? e['data']['to'],
        }),
      }[e['kind']] ??
      e['kind'];

  Widget devicePage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        tr('laboratoryDevices'),
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      SizedBox(height: 12),
      Text(tr('usbDevicesIntro'), style: TextStyle(color: muted)),
      SizedBox(height: 24),
      BridgeSetupCard(supported: usb.supported),
      if (!usb.active && usb.state != 'idle')
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(usbStatus()),
        ),
      SizedBox(height: 24),
      FilledButton.icon(
        onPressed: busy ? null : enroll,
        icon: Icon(Icons.add),
        label: Text(tr('usbRegister')),
      ),
      SizedBox(height: 24),
      if (devices.isEmpty)
        box(
          Text(
            tr('noRegisteredDevicesYouCanUseManualMeasurements'),
            style: TextStyle(color: muted),
          ),
        ),
      for (final d in devices)
        Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: box(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading(Icons.usb, d['name']),
                if (d['transport'] == 'browser_usb') ...[
                  const SizedBox(height: 12),
                  Text(tr('usbBrowserInstrument')),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed:
                        !usb.supported ||
                            (usb.connecting &&
                                usb.attemptedDeviceId != d['id']) ||
                            (usb.active && usb.deviceId != d['id'])
                        ? null
                        : () => usb.deviceId == d['id'] || usb.connecting
                              ? usb.disconnect(
                                  reason: usb.connecting ? 'cancelled' : 'idle',
                                )
                              : usb.connect(d),
                    icon: const Icon(Icons.usb),
                    label: Text(
                      tr(
                        usb.connecting && usb.attemptedDeviceId == d['id']
                            ? 'usbCancelConnect'
                            : usb.deviceId == d['id']
                            ? 'usbDisconnect'
                            : 'usbConnect',
                      ),
                    ),
                  ),
                  if (usb.attemptedDeviceId == d['id'])
                    UsbConnectionStatus(
                      key: ValueKey('usb-status-${d['id']}'),
                      message: usbStatus(),
                      busy: usb.connecting || usb.state == 'reading',
                    ),
                  if (usb.lastResult.isNotEmpty && usb.deviceId == d['id'])
                    Text(tr('usbResult_${usb.lastResult}')),
                ],
                SizedBox(height: 12),
                badge(
                  d['last_seen'] != null &&
                          DateTime.now().millisecondsSinceEpoch / 1000 -
                                  d['last_seen'] <
                              15
                      ? tr('connected')
                      : tr('disconnected'),
                  muted,
                ),
                SizedBox(height: 12),
                Text(
                  tr('deviceDetails', {
                    'points': (d['points'] as List).join(' · '),
                    'calibration': d['calibration_id'],
                    'source': AppStrings.of(
                      context,
                    ).label(d['simulated'] == 1 ? 'simulated' : 'instrumented'),
                  }),
                  style: TextStyle(color: muted),
                ),
                SizedBox(height: 12),
                TextButton(
                  onPressed: () => action(() async {
                    await api.request(
                      '/devices/${d['id']}/revoke',
                      method: 'POST',
                    );
                    toast(tr('credentialRevoked'));
                  }),
                  child: Text(
                    tr(
                      d['transport'] == 'browser_usb'
                          ? 'usbReleaseTabs'
                          : 'revokeCredential',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Future<void> post(String path, [dynamic data]) => action(() async {
    await api.request(
      '/sessions/${selected!['id']}/$path',
      method: 'POST',
      data: data,
    );
  });
  Future<void> createSession() async {
    final draft = await api.outbox.draft(api.scope) ?? {};
    if (!mounted) return;
    final title = TextEditingController(text: draft['title'] ?? '');
    final expected = TextEditingController(text: draft['expected'] ?? '');
    final symptoms = TextEditingController(text: draft['symptoms'] ?? '');
    final setup = TextEditingController(text: draft['setup'] ?? '');
    final supply = TextEditingController(
      text: draft['supply_v'] is num ? formatNumber(draft['supply_v'] as num) : '',
    );
    String family = draft['family'] ?? 'microcontroller';
    String purpose = draft['purpose'] ?? 'diagnosis';
    final accepted = await dialog(
      tr('newSession'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: purpose,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(
                label: RequiredLabel(tr('sessionPurpose')),
              ),
              items: [
                DropdownMenuItem(
                  value: 'diagnosis',
                  child: Text(tr('purposeDiagnosis')),
                ),
                DropdownMenuItem(
                  value: 'check_operation',
                  child: Text(tr('purposeCheckOperation')),
                ),
              ],
              onChanged: (value) => update(() => purpose = value!),
            ),
            if (purpose == 'check_operation') ...[
              const SizedBox(height: 12),
              Text(tr('operationAssessmentHelp')),
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: family,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(
                label: RequiredLabel(tr('circuitFamily')),
              ),
              items: [
                for (final f in families.entries)
                  DropdownMenuItem(value: f.key, child: Text(f.value)),
              ],
              onChanged: (v) => update(() => family = v!),
            ),
            const SizedBox(height: 12),
            Text(tr('${family}Help')),
            const SizedBox(height: 16),
            field(setup, tr('projectSetup'), lines: 2,
              hint: tr('${family}SetupHint'), required: ['microcontroller', 'custom'].contains(family), maxLength: 2000),
            const SizedBox(height: 16),
            field(title, tr('sessionName'), minLength: 3, maxLength: 120),
            SizedBox(height: 16),
            field(
              supply,
              tr('supplyVoltageMaximum5V'),
              numeric: true,
              positive: true,
              hint: tr('supplyChoiceHint'),
            ),
            SizedBox(height: 16),
            field(expected, tr('whatShouldItDo'), lines: 3, minLength: 5,
              maxLength: 2000, hint: tr('${family}ExpectedHint')),
            SizedBox(height: 16),
            field(
              symptoms,
              tr(
                purpose == 'diagnosis'
                    ? 'whatIsHappening'
                    : 'optionalObservations',
              ),
              lines: 3,
              required: purpose == 'diagnosis',
              minLength: 5,
              maxLength: 2000,
              hint: tr(purpose == 'diagnosis' ? '${family}SymptomsHint' : 'optionalObservationHint'),
            ),
            SizedBox(height: 12),
            Text(
              tr('theSchematicAndCriteriaAreConfirmedInThe'),
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      ),
      tr('createSession'),
    );
    final data = {
      'title': title.text.trim(),
      'purpose': purpose,
      'family': family,
      'setup': setup.text.trim(),
      'expected': expected.text.trim(),
      'symptoms': symptoms.text.trim(),
      'supply_v': double.tryParse(supply.text.replaceAll(',', '.')),
    };
    await api.outbox.saveDraft(api.scope, data);
    if (accepted == true) {
      await action(() async {
        final s = await api.request('/sessions', method: 'POST', data: data);
        await api.outbox.saveDraft(api.scope, {});
        if (mounted) context.go('/?session=${s['id']}');
      });
    }
    for (final c in [title, expected, symptoms, supply, setup]) {
      c.dispose();
    }
  }

  Future<void> requestAnalysis() async {
    setState(() => analysisRequested = true);
    try {
      await post('analysis');
    } finally {
      if (mounted) setState(() => analysisRequested = false);
    }
  }

  Future<void> editSpec() async {
    final session = selected!;
    final specification = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SpecificationDialog(
        specification: Map<String, dynamic>.from(session['specification']),
        supplyVoltage: (session['supply_v'] as num).toDouble(),
        project: '${session['setup'] ?? ''}\n${session['expected']}',
      ),
    );
    if (specification == null || !mounted) return;
    await action(() async {
      await api.request(
        '/sessions/${session['id']}/specification',
        method: 'PATCH',
        data: {
          ...specification,
          'version': session['version'],
          'confirmed': true,
        },
      );
    });
  }

  Future<void> removeEvidence(dynamic evidence) async {
    final session = selected!;
    final accepted = await dialog(
      tr('removeEvidence'),
      Text(
        tr(
          session['analysis_steps'] > 0
              ? 'removeEvidenceAnalyzedHelp'
              : 'removeEvidenceHelp',
        ),
      ),
      tr('confirmRemoveEvidence'),
    );
    if (accepted == true) {
      await action(() async {
        await api.request(
          '/sessions/${session['id']}/evidence/${evidence['id']}',
          method: 'DELETE',
          data: {'version': session['version'], 'confirmed': true},
        );
        toast(tr('evidenceRemoved'));
      });
    }
  }

  Future<void> measure() async {
    final s = selected!;
    final points = (s['specification']['points'] as List)
        .map((p) => p['id'] as String)
        .toList();
    String point = s['state'] == 'awaiting_measurement'
        ? s['pending_test']['point_id']
        : ((s['completion'] as Map?)?['missing_points'] as List?)
                  ?.firstOrNull ??
              points.first;
    final value = TextEditingController();
    bool confirmed = false;
    bool? observedState;
    bool digital() => booleanPoint(s['specification'], point);
    Map criterion() => measurementPoint(s['specification'], point);
    bool textReading() => criterion()['value_kind'] == 'text';
    bool sensorReading() => criterion()['value_kind'] == 'number';
    final accepted = await dialog(
      tr('recordManualVoltage'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: point,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(
                label: RequiredLabel(tr('testPointRelativeToGnd')),
              ),
              items: [
                for (final p in points)
                  DropdownMenuItem(
                    value: p,
                    child: Text(
                      measurementPointName(s['specification'], p),
                      maxLines: 2,
                    ),
                  ),
              ],
              onChanged: s['state'] == 'awaiting_measurement'
                  ? null
                  : (p) => update(() {
                      point = p!;
                      value.clear();
                      observedState = null;
                    }),
            ),
            const SizedBox(height: 12),
            Text(tr('observationExpectedCriterion', {
              'criterion': AppStrings.of(context).criterion(criterion()),
            })),
            const SizedBox(height: 8),
            Text(tr('observationActualHelp')),
            SizedBox(height: 16),
            if (digital())
              DropdownButtonFormField<bool>(
                isExpanded: true,
                isDense: false,
                key: const ValueKey('boolean-observed-value'),
                initialValue: observedState,
                decoration: InputDecoration(
                  label: RequiredLabel(tr('booleanObservedValue')),
                ),
                items: [
                  DropdownMenuItem(
                    value: true,
                    child: Text(tr(criterion()['kind'] == 'reported_state' ? 'observationYes' : 'booleanTrue'), maxLines: 2),
                  ),
                  DropdownMenuItem(
                    value: false,
                    child: Text(tr(criterion()['kind'] == 'reported_state' ? 'observationNo' : 'booleanFalse'), maxLines: 2),
                  ),
                ],
                validator: (v) => v == null ? tr('fieldRequired') : null,
                onChanged: (v) => update(() => observedState = v),
              )
            else
              field(value, textReading() ? tr('observedText') : sensorReading()
                ? tr('readingWithUnit', {'unit': criterion()['unit']}) : tr('readingInV05'),
                numeric: !textReading(), voltageOnly: !sensorReading(),
                maxLength: textReading() ? 500 : null),
            SizedBox(height: 16),
            CheckboxListTile(
              subtitle: Text(tr('requiredField')),
              value: confirmed,
              onChanged: (v) => update(() => confirmed = v!),
              contentPadding: EdgeInsets.zero,
              title: Text(
                tr(
                  digital() || textReading() || sensorReading()
                      ? 'confirmBooleanObservationConditions'
                      : 'iConfirmTheInstrumentRangeCommonGndAnd',
                ),
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
      tr('saveReading'),
      validate: () =>
          confirmed ? null : tr('confirmTheConditionsBeforeMeasuring'),
    );
    if (accepted == true) {
      await action(() async {
        if (!confirmed) {
          throw Exception(tr('confirmTheConditionsBeforeMeasuring'));
        }
        final synced = await api.saveMeasurement(s['id'], {
          'client_id': clientId(),
          'point_id': point,
          'value': digital()
              ? observedState
              : textReading() ? value.text.trim()
              : double.tryParse(value.text.replaceAll(',', '.')),
          'unit': digital() ? 'boolean' : textReading() ? 'text'
            : sensorReading() ? criterion()['unit'] : 'V',
          'conditions_confirmed': true,
          'measured_at': DateTime.now().millisecondsSinceEpoch / 1000,
        });
        toast(
          synced
              ? tr('readingRecorded')
              : tr('savedLocallyAwaitingSynchronization'),
        );
      });
    }
    value.dispose();
  }

  Future<void> recordFunctionalCheck() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => FunctionalCheckDialog(
        criteria: selected!['specification']['functional_description'] ?? '',
      ),
    );
    if (result != null) {
      await post('functional-check', {
        ...result,
        'client_id': clientId(),
        'performed_at': DateTime.now().millisecondsSinceEpoch / 1000,
        'confirmed': true,
      });
    }
  }

  Future<void> recordBaselineCheck() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => FunctionalCheckDialog(
        baseline: true,
        criteria: selected!['specification']['functional_description'] ?? '',
      ),
    );
    if (result != null) {
      await post('baseline-check', {
        ...result,
        'client_id': clientId(),
        'performed_at': DateTime.now().millisecondsSinceEpoch / 1000,
        'confirmed': true,
      });
    }
  }

  Future<void> closeInvestigation() async {
    final reason = TextEditingController();
    final accepted = await dialog(
      tr('finishWithoutVerification'),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('closeInvestigationHelp')),
          SizedBox(height: 16),
          field(reason, tr('closureReason'), minLength: 5, lines: 3),
        ],
      ),
      tr('confirmCloseInvestigation'),
    );
    if (accepted == true) {
      if (reason.text.trim().length < 5) {
        toast(tr('closeReasonRequired'));
      } else {
        await post('close', {
          'version': selected!['version'],
          'reason': reason.text.trim(),
          'confirmed': true,
        });
      }
    }
    reason.dispose();
  }

  Future<void> confirmIntervention() async {
    final text = TextEditingController();
    final accepted = await dialog(
      tr('confirmHumanIntervention'),
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('disconnectPowerBeforeChangingConnectionsDescribeTheChange'),
            style: TextStyle(color: muted),
          ),
          SizedBox(height: 16),
          field(text, tr('completedIntervention'), minLength: 5, lines: 4),
        ],
      ),
      tr('confirmCompletedChange'),
    );
    if (accepted == true) {
      await post('interventions', {
        'description': text.text,
        'confirmed': true,
      });
    }
    text.dispose();
  }

  Future<void> confirmConnection() async {
    final text = TextEditingController();
    final accepted = await dialog(
      tr('confirmPhysicalConnection'),
      field(
        text,
        tr('describeTheConnectionYouChecked'),
        minLength: 5,
        lines: 3,
      ),
      tr('confirmReview'),
    );
    if (accepted == true) {
      await action(() async {
        await api.request(
          '/sessions/${selected!['id']}/confirmation',
          method: 'POST',
          data: {'description': text.text, 'confirmed': true},
        );
        await api.request(
          '/sessions/${selected!['id']}/analysis',
          method: 'POST',
        );
      });
    }
    text.dispose();
  }

  Future<void> capture() async {
    ImageSource source = ImageSource.gallery;
    if (!kIsWeb) {
      final useCamera = await dialog(
        tr('captureEvidence'),
        Text(tr('useTheCameraForANewViewOr')),
        tr('useCamera'),
        cancel: tr('gallery'),
      );
      if (useCamera == null) return;
      source = useCamera ? ImageSource.camera : ImageSource.gallery;
    }
    await action(() async {
      final image = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2400,
        imageQuality: 90,
      );
      if (image == null) return;
      final resumeAfterUpload = selected!['state'] == 'awaiting_evidence';
      final synced = await api.upload(
        selected!['id'],
        await image.readAsBytes(),
        image.name,
      );
      if (synced && resumeAfterUpload) {
        await api.request(
          '/sessions/${selected!['id']}/analysis',
          method: 'POST',
        );
      }
      toast(synced ? tr('evidenceAttached') : tr('imageSavedToTheLocalQueue'));
    });
  }

  Future<void> hardware() async {
    if (devices.isEmpty) {
      toast(tr('registerABridgeUnderDevicesOrEnterA'));
      return;
    }
    String device = devices.first['id'];
    final s = selected!;
    final points = (s['specification']['points'] as List)
        .where(
          (p) => instrumentSupportsObservation(p as Map) &&
            devices.any((d) => (d['points'] as List).contains(p['id'])),
        )
        .toList();
    final requested = s['state'] == 'awaiting_measurement'
        ? s['pending_test']['point_id']
        : null;
    if (points.isEmpty ||
        (requested != null && !points.any((p) => p['id'] == requested))) {
      toast(tr('bridgePointUnavailable'));
      return;
    }
    String point = requested ?? points.first['id'];
    List<dynamic> compatibleDevices() {
      int rank(dynamic d) => usb.deviceId == d['id']
          ? 0
          : d['last_seen'] != null &&
                DateTime.now().millisecondsSinceEpoch / 1000 -
                        (d['last_seen'] as num) <
                    15
          ? 1
          : 2;
      final candidates = devices
          .where((d) => (d['points'] as List).contains(point))
          .toList();
      candidates.sort((a, b) => rank(a).compareTo(rank(b)));
      return candidates;
    }

    device = compatibleDevices().first['id'];
    bool confirmed = false;
    final accepted = await dialog(
      tr('readInstrumentedPoint'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: device,
              decoration: InputDecoration(
                label: RequiredLabel(tr('usbInstrument')),
              ),
              items: [
                for (final d in compatibleDevices())
                  DropdownMenuItem(
                    value: d['id'] as String,
                    child: Text(
                      '${d['name']} ${d['transport'] == 'browser_usb'
                          ? tr('usbBrowserShort')
                          : d['simulated'] == 1
                          ? tr('simulated')
                          : ''}',
                    ),
                  ),
              ],
              onChanged: (v) => update(() => device = v!),
            ),
            SizedBox(height: 16),
            HardwarePointField(
              specification: s['specification'],
              points: points,
              value: point,
              locked: requested != null,
              onChanged: (v) => update(() {
                point = v;
                if (!compatibleDevices().any((d) => d['id'] == device)) {
                  device = compatibleDevices().first['id'];
                }
              }),
            ),
            SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              subtitle: Text(tr('requiredField')),
              value: confirmed,
              onChanged: (v) => update(() => confirmed = v!),
              title: Text(
                tr('iConfirmThePointRangeAndElectricalConditions'),
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
      tr('requestReading'),
      validate: () => confirmed ? null : tr('confirmTheElectricalConditions'),
    );
    if (accepted == true) {
      await action(() async {
        if (!confirmed) throw Exception(tr('confirmTheElectricalConditions'));
        await api.request(
          '/sessions/${s['id']}/hardware',
          method: 'POST',
          data: {
            'device_id': device,
            'point_id': point,
            'conditions_confirmed': true,
          },
        );
      });
    }
  }

  Future<void> pair() => action(() async {
    final result = await api.request(
      '/sessions/${selected!['id']}/pairing',
      method: 'POST',
    );
    await showText(
      tr('reviewInvitation5Minutes'),
      result['code'],
      tr('anAuthenticatedPersonCanRedeemThisCodeOnce'),
    );
  });
  Future<void> redeem() async {
    final code = TextEditingController();
    final accepted = await dialog(
      tr('openInvitation'),
      field(code, tr('temporaryCode')),
      tr('openSession'),
    );
    if (accepted == true) {
      await action(() async {
        final result = await api.request(
          '/pairing/redeem',
          method: 'POST',
          data: {'code': code.text.trim()},
        );
        if (mounted) context.go('/?session=${result['session_id']}');
      });
    }
    code.dispose();
  }

  String usbStatus() {
    const states = {
      'idle': 'usbIdle',
      'connecting': 'usbConnecting',
      'connected': 'usbConnected',
      'reading': 'usbReading',
      'unsupported': 'usbUnsupported',
      'permission_denied': 'usbPermissionDenied',
      'port_unavailable': 'usbPortUnavailable',
      'busy': 'usbPortUnavailable',
      'disconnected': 'usbDisconnected',
      'in_use': 'usbInUse',
      'expired': 'usbExpired',
      'backend_update': 'usbBackendUpdate',
      'signed_out': 'usbSignedOut',
      'choosing_port': 'usbChoosingPort',
      'opening_port': 'usbOpeningPort',
      'starting_instrument': 'usbStartingInstrument',
      'registering_server': 'usbRegisteringServer',
      'cancelled': 'usbCancelled',
      'open_timeout': 'usbOpenTimeout',
      'server_timeout': 'usbServerTimeout',
      'tab_hidden': 'usbTabHidden',
    };
    return tr(states[usb.state] ?? 'usbConnectionError');
  }

  Future<void> enroll() async {
    final name = TextEditingController();
    final calibration = TextEditingController();
    final accepted = await dialog(
      tr('usbRegister'),
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tr('usbEnrollHint')),
          const SizedBox(height: 16),
          field(name, tr('deviceName'), minLength: 2),
          const SizedBox(height: 16),
          field(calibration, tr('calibrationIdentifier'), minLength: 3),
          const SizedBox(height: 10),
          Text(
            tr('calibrationIdentifierHelp'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Text(
            tr('calibrationNotPrepared'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      tr('usbRegister'),
    );
    if (accepted == true) {
      await action(() async {
        await api.request(
          '/devices/enroll',
          method: 'POST',
          data: {
            'name': name.text.trim(),
            'calibration_id': calibration.text.trim(),
            'points': ['TP1', 'TP2', 'TP3'],
            'simulated': false,
            'transport': 'browser_usb',
          },
        );
        toast(tr('usbRegistered'));
      });
    }
    name.dispose();
    calibration.dispose();
  }

  Future<void> showReport({bool readable = false}) => action(() async {
    final result = await api.request(
      '/sessions/${selected!['id']}/report${readable ? '?format=markdown' : ''}',
    );
    await showText(
      tr('sessionReport'),
      readable
          ? result as String
          : JsonEncoder.withIndent('  ').convert(result),
      tr(readable ? 'reportDescription' : 'copyTheJsonToSaveOrExportThe'),
    );
  });
  Future<void> showText(String title, String content, String subtitle) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        insetPadding: formDialogInsets(context),
        title: Text(title),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle, style: TextStyle(color: muted)),
                SizedBox(height: 18),
                SelectableText(
                  content,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: content));
              toast(tr('copiedToClipboard'));
            },
            child: Text(tr('copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('close')),
          ),
        ],
      ),
    );
  }

  Future<bool?> dialog(
    String title,
    Widget content,
    String accept, {
    String? cancel,
    String? Function()? validate,
  }) async {
    final form = GlobalKey<FormState>();
    String? validationError;
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          insetPadding: formDialogInsets(context),
          title: Text(title),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (content is! Text) const RequiredFieldsNotice(),
                    content,
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        validationError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(cancel ?? tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                final validFields = form.currentState!.validate();
                final message = validate?.call();
                update(() => validationError = message);
                if (validFields && message == null) {
                  Navigator.pop(context, true);
                }
              },
              child: Text(accept),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    return result;
  }

  Widget field(
    TextEditingController controller,
    String label, {
    int lines = 1,
    bool numeric = false,
    bool positive = false,
    bool required = true,
    int minLength = 1,
    int? maxLength,
    String? hint,
    bool voltageOnly = true,
  }) => TextFormField(
    key: ValueKey((controller, required)),
    controller: controller,
    maxLines: lines,
    maxLength: maxLength,
    keyboardType: numeric
        ? TextInputType.numberWithOptions(decimal: true, signed: !voltageOnly)
        : null,
    decoration: InputDecoration(
      label: required ? RequiredLabel(label) : Text(label),
      hintText: hint,
      hintMaxLines: 3,
      counterText: '',
    ),
    validator: (text) {
      final value = text?.trim() ?? '';
      if (!required && value.isEmpty) return null;
      if (required && value.isEmpty) return tr('fieldRequired');
      if (numeric) {
        final number = double.tryParse(value.replaceAll(',', '.'));
        if (number == null ||
            !number.isFinite ||
            (voltageOnly && (number > 5 || number < 0)) ||
            (positive && number == 0)) {
          return tr(
            !voltageOnly ? 'validNumberRequired' : positive ? 'positiveSupplyRequired' : 'validVoltageRequired',
          );
        }
      }
      if (required && value.length < minLength) {
        return tr('fieldMinimumCharacters', {'count': minLength});
      }
      return null;
    },
  );
  Widget heading(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 19, color: mint),
      SizedBox(width: 10),
      Flexible(
        child: Text(
          label,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
  Widget box(Widget child, {bool accent = false}) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(
        color: accent ? mint.withValues(alpha: .4) : Color(0xFF29343E),
      ),
    ),
    child: child,
  );
  Widget badge(String label, Color color) => Container(
    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withValues(alpha: .17)),
    ),
    child: Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: .5,
      ),
    ),
  );
}

class EvidenceThumbnail extends StatefulWidget {
  final CircuitApi api;
  final String sessionId;
  final dynamic evidence;
  const EvidenceThumbnail({
    super.key,
    required this.api,
    required this.sessionId,
    required this.evidence,
  });
  @override
  State<EvidenceThumbnail> createState() => _EvidenceThumbnailState();
}

class _EvidenceThumbnailState extends State<EvidenceThumbnail> {
  String tr(String key) => AppStrings.of(context).t(key);
  late Future<Uint8List> image = loadImage();
  Future<Uint8List> loadImage() => widget.api.downloadEvidence(
    widget.sessionId,
    widget.evidence['id'] as String,
  );

  @override
  void didUpdateWidget(covariant EvidenceThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.evidence['id'] != widget.evidence['id']) {
      image = loadImage();
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 190,
    height: 150,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: FutureBuilder<Uint8List>(
        future: image,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() => image = loadImage()),
                child: Text('${tr('unableToLoad')} · ${tr('retry')}'),
              ),
            );
          }
          final bytes = snap.data!;
          return InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  Dialog(child: InteractiveViewer(child: Image.memory(bytes))),
            ),
            child: Image.memory(bytes, fit: BoxFit.cover),
          );
        },
      ),
    ),
  );
}

class CircuitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = mint.withValues(alpha: .32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final grid = Paint()..color = muted.withValues(alpha: .16);
    for (double x = 8; x < size.width; x += 18) {
      for (double y = 8; y < size.height; y += 18) {
        canvas.drawCircle(Offset(x, y), .7, grid);
      }
    }
    final w = size.width, h = size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .38, h * .25, w * .24, h * .5),
        Radius.circular(7),
      ),
      line,
    );
    for (var i = 0; i < 4; i++) {
      final y = h * (.34 + i * .1);
      final left = Path()
        ..moveTo(w * .38, y)
        ..lineTo(w * (.24 - i * .025), y)
        ..lineTo(w * (.24 - i * .025), h * (.2 + i * .2))
        ..lineTo(w * .07, h * (.2 + i * .2));
      canvas.drawPath(left, line);
      canvas.drawCircle(Offset(w * .07, h * (.2 + i * .2)), 3, line);
      final right = Path()
        ..moveTo(w * .62, y)
        ..lineTo(w * (.74 + i * .025), y)
        ..lineTo(w * (.74 + i * .025), h * (.2 + i * .2))
        ..lineTo(w * .93, h * (.2 + i * .2));
      canvas.drawPath(right, line);
      canvas.drawCircle(Offset(w * .93, h * (.2 + i * .2)), 3, line);
    }
    final signal = Path()..moveTo(w * .43, h * .5);
    for (var i = 0; i < 40; i++) {
      signal.lineTo(w * (.43 + i * .0035), h * (.5 + math.sin(i * .3) * .12));
    }
    canvas.drawPath(
      signal,
      Paint()
        ..color = mint
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
