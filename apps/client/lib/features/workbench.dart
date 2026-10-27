import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../core/networking/api.dart';
import '../main.dart';
import '../l10n/app_strings.dart';
import '../l10n/language.dart';
import 'accounts.dart';
import 'investigation.dart';
import 'metrics.dart';
import '../core/brand.dart';
import '../core/password_visibility.dart';

class Workbench extends ConsumerStatefulWidget {
  final String? sessionId;
  final bool registering;
  const Workbench({super.key, this.sessionId, this.registering = false});
  @override
  ConsumerState<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends ConsumerState<Workbench> {
  String tr(String key, [Map<String, Object?> args = const {}]) =>
      AppStrings.of(context).t(key, args);
  dynamic localized(Map data, String field) =>
      (data['translations'] as Map?)?[api.language]?[field] ?? data[field];
  Map<String, String> get families => {
    'led_resistor': tr('ledResistor'),
    'voltage_divider': tr('voltageDivider'),
    'analog_sensor': tr('analogSensor'),
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
    'resolved': tr('criteriaMet'),
    'inconclusive': tr('inconclusive'),
    'cancelled': tr('cancelled'),
  };

  late final CircuitApi api;
  final mail = TextEditingController();
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  final search = TextEditingController();
  List<dynamic> sessions = [], devices = [], events = [];
  Map<String, dynamic>? selected;
  String mode = '', section = 'sessions';
  bool providerConfigured = false;
  bool passwordVisible = false, confirmationVisible = false;
  String? error;
  bool busy = false, restoring = true, refreshing = false;
  int pending = 0;
  Timer? timer;
  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    api = ref.read(apiProvider);
    api.addListener(authChanged);
    init();
    timer = Timer.periodic(Duration(seconds: 4), (_) {
      if (api.signedIn && !busy && !refreshing) refresh(silent: true);
    });
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
  void dispose() {
    timer?.cancel();
    api.removeListener(authChanged);
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

  Future<void> refresh({bool silent = false}) async {
    if (refreshing) return;
    refreshing = true;
    try {
      final queue = await api.outbox.pending(api.scope);
      if (mounted) setState(() => pending = queue.length);
      if (queue.isNotEmpty) {
        await api.sync();
      }
      final data = await api.request('/sessions') as List;
      final account = await api.request('/auth/me');
      if (account is Map) api.account = Map<String, dynamic>.from(account);
      final hardware = await api.request('/devices') as List;
      final health = (await api.dio.get('/health/live')).data;
      Map<String, dynamic>? detail;
      List<dynamic> history = [];
      if (widget.sessionId != null) {
        detail = Map<String, dynamic>.from(
          await api.request('/sessions/${widget.sessionId}'),
        );
        history = await api.request('/sessions/${widget.sessionId}/events');
      }
      if (mounted) {
        setState(() {
          sessions = data;
          devices = hardware;
          selected = detail;
          events = history;
          mode = health['ai_mode'];
          providerConfigured = health['provider_configured'] == true;
          pending = 0;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && (!silent || !api.signedIn)) {
        setState(() => error = errorMessage(e, language: api.language));
      }
    } finally {
      refreshing = false;
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
                      SizedBox(width: wide ? 16 : 4),
                      IconButton(
                        tooltip: tr('sync'),
                        onPressed: busy
                            ? null
                            : () => action(() => api.sync().then((_) {})),
                        icon: Icon(Icons.sync, size: 20),
                      ),
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: mint.withValues(alpha: .12),
                        child: Text(
                          api.email.isEmpty ? 'C' : api.email[0].toUpperCase(),
                          style: TextStyle(color: mint, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy) LinearProgressIndicator(minHeight: 2),
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
            SizedBox(height: 28),
            Text(
              tr('laboratory'),
              style: TextStyle(color: muted, fontSize: 10, letterSpacing: 2),
            ),
            SizedBox(height: 14),
            nav(Icons.grid_view_rounded, tr('mySessions'), 'sessions'),
            nav(Icons.usb_rounded, tr('devices'), 'devices'),
            if (api.isAdmin) ...[
              nav(Icons.insights_outlined, tr('metricsNav'), 'metrics'),
              nav(Icons.manage_accounts_outlined, tr('users'), 'users'),
            ],
            SizedBox(height: 28),
            Divider(),
            SizedBox(height: 20),
            Text(
              tr('aVerifiableCycle'),
              style: TextStyle(fontSize: 10, letterSpacing: 1.4, color: muted),
            ),
            SizedBox(height: 16),
            for (final item in [
              tr('01Observe'),
              tr('02Measure'),
              tr('03Repair'),
              tr('04Verify'),
            ])
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(item, style: TextStyle(color: muted, fontSize: 12)),
              ),
            Spacer(),
            Container(
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: mint.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: mint.withValues(alpha: .15)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.electrical_services, color: mint, size: 20),
                  SizedBox(height: 10),
                  Text(
                    tr('lowVoltageLaboratory'),
                    style: TextStyle(fontSize: 12),
                  ),
                  SizedBox(height: 6),
                  Text(
                    tr('confirmedPointsHumanRepairs'),
                    style: TextStyle(color: muted, fontSize: 11, height: 1.7),
                  ),
                ],
              ),
            ),
            SizedBox(height: 15),
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
                      SizedBox(height: 30),
                      TextField(
                        controller: mail,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: tr('emailAddress'),
                          prefixIcon: Icon(Icons.alternate_email, size: 18),
                        ),
                      ),
                      SizedBox(height: 18),
                      TextField(
                        controller: password,
                        obscureText: !passwordVisible,
                        decoration: InputDecoration(
                          labelText: tr('password'),
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
                            labelText: tr('confirmPassword'),
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
                '${sessions.where((s) => !['resolved', 'inconclusive', 'cancelled'].contains(s['state'])).length}',
                Icons.hub_outlined,
                tr('openDiagnoses'),
                c.maxWidth,
              ),
              stat(
                tr('criteriaMetLabel'),
                '${sessions.where((s) => s['state'] == 'resolved').length}',
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
          for (final s in filtered)
            Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => context.go('/?session=${s['id']}'),
                child: box(
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: mint.withValues(alpha: .07),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.memory, color: mint, size: 24),
                      ),
                      SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s['title'],
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              '${families[s['family']]}  ·  ${s['supply_v']} V',
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 10),
                      Flexible(
                        child: badge(
                          states[s['state']] ?? s['state'],
                          s['state'] == 'resolved' ? mint : muted,
                        ),
                      ),
                      SizedBox(width: 12),
                      Icon(Icons.arrow_forward, size: 18, color: muted),
                    ],
                  ),
                ),
              ),
            ),
        SizedBox(height: 24),
        Text(
          tr('circuitlabAiTraceableDiagnosis'),
          style: TextStyle(color: muted, letterSpacing: 1.2, fontSize: 10),
        ),
      ],
    );
  }

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
              Text(
                label,
                style: TextStyle(
                  color: muted,
                  fontSize: 10,
                  letterSpacing: 1.4,
                ),
              ),
              Spacer(),
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
            badge(
              states[state] ?? state,
              state == 'resolved' ? mint : Colors.amber,
            ),
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
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            if (editable &&
                ['draft', 'ready'].contains(state) &&
                s['analysis_steps'] == 0)
              OutlinedButton.icon(
                onPressed: busy ? null : editSpec,
                icon: Icon(Icons.account_tree_outlined, size: 17),
                label: Text(tr('confirmSchematic')),
              ),
            if (editable && ['ready', 'awaiting_evidence'].contains(state))
              FilledButton.icon(
                onPressed: busy ? null : () => post('analysis'),
                icon: Icon(Icons.auto_awesome, size: 17),
                label: Text(tr('analyzeEvidence')),
              ),
            if (editable && state == 'awaiting_confirmation')
              FilledButton.icon(
                onPressed: busy ? null : confirmConnection,
                icon: Icon(Icons.fact_check_outlined, size: 17),
                label: Text(tr('confirmConnection')),
              ),
            if (editable)
              OutlinedButton.icon(
                onPressed: busy ? null : pair,
                icon: Icon(Icons.devices, size: 17),
                label: Text(tr('shareReview')),
              ),
            OutlinedButton.icon(
              onPressed: () => showReport(readable: true),
              icon: Icon(Icons.article_outlined, size: 17),
              label: Text(tr('readableReport')),
            ),
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
        box(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading(Icons.flag_outlined, tr('sessionObjective')),
              SizedBox(height: 16),
              Text(
                tr('expectedResult'),
                style: TextStyle(color: mint, fontSize: 10, letterSpacing: 1.2),
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
              Text(s['symptoms']),
            ],
          ),
        ),
        SizedBox(height: 18),
        if (plan != null) ...[
          box(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading(
                  Icons.assistant_outlined,
                  state == 'verifying'
                      ? tr('functionalVerification')
                      : tr('nextStep'),
                ),
                SizedBox(height: 16),
                Text(
                  localized(plan, 'instruction') ?? '',
                  style: TextStyle(fontSize: 17, height: 1.6),
                ),
                if (plan['rationale'] != null) ...[
                  SizedBox(height: 10),
                  Text(
                    localized(plan, 'rationale'),
                    style: TextStyle(color: muted),
                  ),
                ],
                SizedBox(height: 18),
                if (editable &&
                    ['awaiting_measurement', 'verifying'].contains(state))
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: busy ? null : measure,
                        icon: Icon(Icons.speed, size: 17),
                        label: Text(tr('recordMeasurement')),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy ? null : hardware,
                        icon: Icon(Icons.usb, size: 17),
                        label: Text(tr('readUsingBridge')),
                      ),
                    ],
                  ),
                if (editable && state == 'awaiting_intervention')
                  FilledButton(
                    onPressed: busy ? null : confirmIntervention,
                    child: Text(tr('recordCompletedIntervention')),
                  ),
                if (editable && state == 'verifying')
                  Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: FilledButton(
                      onPressed: busy ? null : () => post('verification'),
                      child: Text(tr('evaluateFunctionalCriteria')),
                    ),
                  ),
              ],
            ),
            accent: true,
          ),
          SizedBox(height: 18),
        ],
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
                      EvidenceThumbnail(
                        api: api,
                        sessionId: s['id'],
                        evidence: e,
                      ),
                  ],
                ),
            ],
          ),
        ),
        SizedBox(height: 18),
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
              for (final h in (s['hypotheses'] as List).reversed.take(6)) ...[
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
                    tr('pointCriterion', {
                      'point': p['id'],
                      'label': p['label'],
                      'min': p['min_v'],
                      'max': p['max_v'],
                    }),
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
                        m['point_id'],
                        style: TextStyle(
                          color: mint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${(m['value'] as num).toStringAsFixed(3)} V',
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
                  v['data']['passed'] == true
                      ? tr('theElectricalCriteriaAreMet')
                      : tr('theFunctionalCriterionIsNotMet'),
                  style: TextStyle(
                    color: v['data']['passed'] == true ? mint : Colors.amber,
                  ),
                ),
                if (v['data']['physical_verification'] != true)
                  Text(
                    tr('thisDoesNotEstablishFullPhysicalVerification'),
                    style: TextStyle(color: Colors.amber),
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
        InvestigationPanels(
          session: s,
          busy: busy,
          onGenerate: () => post('storyboards'),
        ),
      ],
    );
  }

  String eventLabel(dynamic e) =>
      {
        'session_created': tr('sessionCreated'),
        'specification_confirmed': tr('schematicAndCriteriaConfirmed'),
        'evidence_added': tr('imageAttached'),
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
        'job_error': tr('analysisError', {
          'error': AppStrings.of(context).label(e['data']['code']),
        }),
        'hardware_failed': tr('readingError', {
          'error': AppStrings.of(context).label(e['data']['status']),
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
      Text(
        tr('theBridgeOpensAnOutboundConnectionItOnly'),
        style: TextStyle(color: muted),
      ),
      SizedBox(height: 24),
      FilledButton.icon(
        onPressed: busy ? null : enroll,
        icon: Icon(Icons.add),
        label: Text(tr('registerBridge')),
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
                  child: Text(tr('revokeCredential')),
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
    final supply = TextEditingController(text: '${draft['supply_v'] ?? 5.0}');
    String family = draft['family'] ?? 'analog_sensor';
    final accepted = await dialog(
      tr('newSession'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(title, tr('sessionName')),
            SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: family,
              decoration: InputDecoration(labelText: tr('circuitFamily')),
              items: [
                for (final f in families.entries)
                  DropdownMenuItem(value: f.key, child: Text(f.value)),
              ],
              onChanged: (v) => update(() => family = v!),
            ),
            SizedBox(height: 16),
            field(supply, tr('supplyVoltageMaximum5V'), numeric: true),
            SizedBox(height: 16),
            field(expected, tr('whatShouldItDo'), lines: 3),
            SizedBox(height: 16),
            field(symptoms, tr('whatIsHappening'), lines: 3),
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
      'title': title.text,
      'family': family,
      'expected': expected.text,
      'symptoms': symptoms.text,
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
    for (final c in [title, expected, symptoms, supply]) {
      c.dispose();
    }
  }

  Future<void> editSpec() async {
    final s = selected!;
    final current = s['specification'];
    final connections = TextEditingController(
      text: (current['connections'] as List?)?.join('\n') ?? '',
    );
    final description = TextEditingController(
      text: current['functional_description'] ?? '',
    );
    final points =
        (current['points'] as List?) ??
        [
          {'id': 'TP1', 'label': '', 'min_v': '', 'max_v': ''},
        ];
    final rows = List.generate(
      3,
      (i) => List.generate(
        3,
        (j) => TextEditingController(
          text: i < points.length
              ? '${points[i][['label', 'min_v', 'max_v'][j]]}'
              : '',
        ),
      ),
    );
    final accepted = await dialog(
      tr('schematicAndInitialCriteria'),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('physicallyConfirmTheConnectionsDefineTheRangesThat'),
            style: TextStyle(color: muted),
          ),
          SizedBox(height: 18),
          field(connections, tr('confirmedConnectionsOnePerLine'), lines: 4),
          SizedBox(height: 18),
          field(description, tr('functionalTestCondition'), lines: 3),
          SizedBox(height: 18),
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Text('TP${i + 1}'),
                  SizedBox(width: 10),
                  Expanded(flex: 2, child: field(rows[i][0], tr('label'))),
                  SizedBox(width: 8),
                  Expanded(child: field(rows[i][1], tr('minV'), numeric: true)),
                  SizedBox(width: 8),
                  Expanded(child: field(rows[i][2], tr('maxV'), numeric: true)),
                ],
              ),
            ),
          Text(
            tr('leaveUnusedPointsEmptyAllDefinedPointsWill'),
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ),
      tr('iConfirmTheSchematicAndCriteria'),
    );
    if (accepted == true) {
      await action(() async {
        await api.request(
          '/sessions/${s['id']}/specification',
          method: 'PATCH',
          data: {
            'version': s['version'],
            'confirmed': true,
            'connections': connections.text
                .split('\n')
                .where((x) => x.trim().isNotEmpty)
                .toList(),
            'functional_description': description.text,
            'points': [
              for (var i = 0; i < 3; i++)
                if (rows[i][0].text.trim().isNotEmpty)
                  {
                    'id': 'TP${i + 1}',
                    'label': rows[i][0].text,
                    'min_v': double.tryParse(
                      rows[i][1].text.replaceAll(',', '.'),
                    ),
                    'max_v': double.tryParse(
                      rows[i][2].text.replaceAll(',', '.'),
                    ),
                  },
            ],
          },
        );
      });
    }
    connections.dispose();
    description.dispose();
    for (final row in rows) {
      for (final c in row) {
        c.dispose();
      }
    }
  }

  Future<void> measure() async {
    final s = selected!;
    final points = (s['specification']['points'] as List)
        .map((p) => p['id'] as String)
        .toList();
    String point = s['state'] == 'awaiting_measurement'
        ? s['pending_test']['point_id']
        : points.first;
    final value = TextEditingController();
    bool confirmed = false;
    final accepted = await dialog(
      tr('recordManualVoltage'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: point,
              decoration: InputDecoration(
                labelText: tr('testPointRelativeToGnd'),
              ),
              items: [
                for (final p in points)
                  DropdownMenuItem(value: p, child: Text(p)),
              ],
              onChanged: s['state'] == 'awaiting_measurement'
                  ? null
                  : (p) => update(() => point = p!),
            ),
            SizedBox(height: 16),
            field(value, tr('readingInV05'), numeric: true),
            SizedBox(height: 16),
            CheckboxListTile(
              value: confirmed,
              onChanged: (v) => update(() => confirmed = v!),
              contentPadding: EdgeInsets.zero,
              title: Text(
                tr('iConfirmTheInstrumentRangeCommonGndAnd'),
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
      tr('saveReading'),
    );
    if (accepted == true) {
      await action(() async {
        if (!confirmed) {
          throw Exception(tr('confirmTheConditionsBeforeMeasuring'));
        }
        final synced = await api.saveMeasurement(s['id'], {
          'client_id': clientId(),
          'point_id': point,
          'value': double.tryParse(value.text.replaceAll(',', '.')),
          'unit': 'V',
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
          field(text, tr('completedIntervention'), lines: 4),
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
      field(text, tr('describeTheConnectionYouChecked'), lines: 3),
      tr('confirmReview'),
    );
    if (accepted == true) {
      await post('confirmation', {'description': text.text, 'confirmed': true});
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
      final synced = await api.upload(
        selected!['id'],
        await image.readAsBytes(),
        image.name,
      );
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
    final points = s['specification']['points'] as List;
    String point = s['state'] == 'awaiting_measurement'
        ? s['pending_test']['point_id']
        : points.first['id'];
    bool confirmed = false;
    final accepted = await dialog(
      tr('readInstrumentedPoint'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: device,
              decoration: InputDecoration(labelText: 'Bridge'),
              items: [
                for (final d in devices)
                  DropdownMenuItem(
                    value: d['id'] as String,
                    child: Text(
                      '${d['name']} ${d['simulated'] == 1 ? tr('simulated') : ''}',
                    ),
                  ),
              ],
              onChanged: (v) => update(() => device = v!),
            ),
            SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: point,
              decoration: InputDecoration(labelText: tr('point')),
              items: [
                for (final p in points)
                  DropdownMenuItem(
                    value: p['id'] as String,
                    child: Text(p['id']),
                  ),
              ],
              onChanged: s['state'] == 'awaiting_measurement'
                  ? null
                  : (v) => update(() => point = v!),
            ),
            SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
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

  Future<void> enroll() async {
    final name = TextEditingController();
    final calibration = TextEditingController();
    bool simulated = true;
    final accepted = await dialog(
      tr('registerBridge'),
      StatefulBuilder(
        builder: (_, update) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(name, tr('deviceName')),
            SizedBox(height: 16),
            field(calibration, tr('calibrationIdentifier')),
            SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: simulated,
              onChanged: (v) => update(() => simulated = v),
              title: Text(tr('simulatedDevice')),
              subtitle: Text(tr('disableOnlyWhenUsingCalibratedInstruments')),
            ),
          ],
        ),
      ),
      tr('generateCredential'),
    );
    if (accepted == true) {
      await action(() async {
        final result = await api.request(
          '/devices/enroll',
          method: 'POST',
          data: {
            'name': name.text,
            'calibration_id': calibration.text,
            'points': ['TP1', 'TP2', 'TP3'],
            'simulated': simulated,
          },
        );
        await showText(
          tr('bridgeCredential'),
          JsonEncoder.withIndent('  ').convert({
            ...result,
            'calibration_id': calibration.text,
            'points': ['TP1', 'TP2', 'TP3'],
            'simulate': simulated,
          }),
          tr('saveItInCredentialsJsonTheCredentialIs'),
        );
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
  }) async {
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(child: content),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancel ?? tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(accept),
          ),
        ],
      ),
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    // The pop result precedes the closing animation. Controllers must remain alive
    // until the route is fully removed from the widget tree.
    await route.completed;
    return result;
  }

  Widget field(
    TextEditingController controller,
    String label, {
    int lines = 1,
    bool numeric = false,
  }) => TextField(
    controller: controller,
    maxLines: lines,
    keyboardType: numeric
        ? TextInputType.numberWithOptions(decimal: true)
        : null,
    decoration: InputDecoration(labelText: label),
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
  late final Future<Response<List<int>>> image = widget.api.dio.get<List<int>>(
    '/sessions/${widget.sessionId}/evidence/${widget.evidence['id']}',
    options: Options(
      responseType: ResponseType.bytes,
      headers: {'Authorization': 'Bearer ${widget.api.access}'},
    ),
  );
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 190,
    height: 150,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: FutureBuilder(
        future: image,
        builder: (_, snap) {
          if (snap.hasError) {
            return Center(child: Text(tr('unableToLoad')));
          }
          if (!snap.hasData) {
            return Center(child: CircularProgressIndicator());
          }
          final bytes = Uint8List.fromList(snap.data!.data!);
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
