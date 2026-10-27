import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/networking/api.dart';
import '../core/password_visibility.dart';
import '../l10n/app_strings.dart';
import '../l10n/language.dart';
import '../main.dart';

class RecoveryPage extends ConsumerStatefulWidget {
  final String? token;
  final bool resetting;
  const RecoveryPage({super.key, this.token, this.resetting = false});
  @override
  ConsumerState<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends ConsumerState<RecoveryPage> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  final token = TextEditingController();
  bool busy = false, done = false;
  bool passwordVisible = false, confirmationVisible = false;
  String? error;
  String tr(String key) => AppStrings.of(context).t(key);
  @override
  void initState() {
    super.initState();
    token.text = widget.token ?? '';
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    confirmation.dispose();
    token.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    final api = ref.read(apiProvider);
    try {
      await api.dio.post(
        widget.resetting ? '/auth/reset-password' : '/auth/forgot-password',
        data: widget.resetting
            ? {'token': token.text.trim(), 'password': password.text}
            : {'email': email.text.trim()},
      );
      if (widget.resetting) await api.clearCredentials();
      password.clear();
      confirmation.clear();
      token.clear();
      if (mounted) setState(() => done = true);
    } catch (e) {
      if (mounted) {
        setState(() => error = errorMessage(e, language: api.language));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.memory, color: mint),
                        SizedBox(width: 8),
                        Expanded(child: Text('CircuitLab AI')),
                        LanguageSelector(),
                      ],
                    ),
                    const SizedBox(height: 28),
                    Text(
                      tr(widget.resetting ? 'resetPassword' : 'forgotPassword'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        done
                            ? (widget.resetting
                                  ? 'passwordUpdated'
                                  : 'recoveryAccepted')
                            : (widget.resetting
                                  ? 'chooseNewPassword'
                                  : 'recoveryInstructions'),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (!done) ...[
                      if (!widget.resetting)
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: InputDecoration(
                            labelText: tr('emailAddress'),
                          ),
                          validator: (v) =>
                              RegExp(
                                r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                              ).hasMatch(v?.trim() ?? '')
                              ? null
                              : tr('validEmailRequired'),
                        ),
                      if (widget.resetting) ...[
                        // Pasting a token also supports Android without an app-link association.
                        if (widget.token == null)
                          TextFormField(
                            controller: token,
                            decoration: InputDecoration(
                              labelText: tr('recoveryCode'),
                            ),
                            validator: (v) => (v?.trim().length ?? 0) >= 32
                                ? null
                                : tr('recoveryCodeRequired'),
                          ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: password,
                          obscureText: !passwordVisible,
                          maxLength: 200,
                          autofillHints: const [AutofillHints.newPassword],
                          decoration: InputDecoration(
                            labelText: tr('newPassword'),
                            suffixIcon: PasswordVisibilityButton(
                              visible: passwordVisible,
                              onPressed: () => setState(
                                () => passwordVisible = !passwordVisible,
                              ),
                            ),
                          ),
                          validator: (v) => (v?.length ?? 0) >= 12
                              ? null
                              : tr('passwordMinimum'),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: confirmation,
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
                          ),
                          validator: (v) => v == password.text
                              ? null
                              : tr('passwordMismatch'),
                        ),
                      ],
                      const SizedBox(height: 20),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            error!,
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                      FilledButton(
                        onPressed: busy ? null : submit,
                        child: Text(
                          tr(
                            busy
                                ? 'processing'
                                : widget.resetting
                                ? 'savePassword'
                                : 'sendRecoveryLink',
                          ),
                        ),
                      ),
                      if (!widget.resetting)
                        TextButton(
                          onPressed: () => context.go('/reset-password'),
                          child: Text(tr('haveRecoveryCode')),
                        ),
                    ],
                    TextButton(
                      onPressed: busy ? null : () => context.go('/'),
                      child: Text(tr('backToLogin')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AccountsPanel extends StatefulWidget {
  final CircuitApi api;
  const AccountsPanel({super.key, required this.api});
  @override
  State<AccountsPanel> createState() => _AccountsPanelState();
}

class _AccountsPanelState extends State<AccountsPanel> {
  final search = TextEditingController();
  List<dynamic> users = [], events = [];
  bool busy = false, more = false, activity = false;
  int offset = 0;
  String? error;
  String tr(String key) => AppStrings.of(context).t(key);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> perform(Future<void> Function() call) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await call();
    } catch (e) {
      if (mounted) {
        setState(() => error = errorMessage(e, language: widget.api.language));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> fetch() async {
    final result = await widget.api.request(
      activity
          ? '/admin/events?offset=$offset'
          : '/admin/users?offset=$offset&q=${Uri.encodeQueryComponent(search.text.trim())}',
    );
    if (mounted) {
      setState(() {
        if (activity) {
          events = result['items'];
        } else {
          users = result['items'];
        }
        more = result['has_more'] == true;
      });
    }
  }

  Future<void> load() => perform(fetch);
  Future<void> create() async {
    final email = TextEditingController(), password = TextEditingController();
    final form = GlobalKey<FormState>();
    String role = 'member';
    bool passwordVisible = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(tr('createUser')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: tr('emailAddress'),
                      ),
                      validator: (v) =>
                          RegExp(
                            r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                          ).hasMatch(v?.trim() ?? '')
                          ? null
                          : tr('validEmailRequired'),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: password,
                      obscureText: !passwordVisible,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: tr('initialPassword'),
                        suffixIcon: PasswordVisibilityButton(
                          visible: passwordVisible,
                          onPressed: () =>
                              update(() => passwordVisible = !passwordVisible),
                        ),
                      ),
                      validator: (v) =>
                          (v?.length ?? 0) >= 12 ? null : tr('passwordMinimum'),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: role,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: tr('role')),
                      items: ['member', 'admin']
                          .map(
                            (r) =>
                                DropdownMenuItem(value: r, child: Text(tr(r))),
                          )
                          .toList(),
                      onChanged: (v) => update(() => role = v!),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(tr('cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(dialog, true);
              },
              child: Text(tr('createUser')),
            ),
          ],
        ),
      ),
    );
    final mail = email.text.trim(), secret = password.text;
    // Dialog controllers are disposed after their route animation ends.
    Future<void>.delayed(const Duration(seconds: 1), () {
      email.dispose();
      password.dispose();
    });
    if (accepted == true && mounted) {
      await perform(() async {
        await widget.api.request(
          '/admin/users',
          method: 'POST',
          data: {'email': mail, 'password': secret, 'role': role},
        );
        offset = 0;
        await fetch();
      });
    }
  }

  Future<bool> confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('confirmAccountChange')),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('confirm')),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> update(Map user, {String? role, bool? active}) async {
    if (!await confirm(
      '${user['email']}\n${tr('accountChangeRevokesSessions')}',
    )) {
      return;
    }
    await perform(() async {
      await widget.api.request(
        '/admin/users/${user['id']}',
        method: 'PATCH',
        data: {
          'role': role ?? user['role'],
          'active': active ?? user['active'],
        },
      );
      await fetch();
    });
  }

  Future<void> recovery(Map user) async {
    if (!await confirm('${tr('sendRecoveryLink')}\n${user['email']}')) return;
    await perform(() async {
      await widget.api.request(
        '/admin/users/${user['id']}/recovery',
        method: 'POST',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('recoveryAccepted'))));
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 20,
        runSpacing: 16,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('userAdministration'),
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                tr('accountAdministrationDescription'),
                style: const TextStyle(color: muted),
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: busy ? null : create,
            icon: const Icon(Icons.person_add_outlined),
            label: Text(tr('createUser')),
          ),
        ],
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 12,
        children: [
          ChoiceChip(
            label: Text(tr('users')),
            selected: !activity,
            onSelected: busy
                ? null
                : (_) {
                    setState(() {
                      activity = false;
                      offset = 0;
                    });
                    load();
                  },
          ),
          ChoiceChip(
            label: Text(tr('accountActivity')),
            selected: activity,
            onSelected: busy
                ? null
                : (_) {
                    setState(() {
                      activity = true;
                      offset = 0;
                    });
                    load();
                  },
          ),
        ],
      ),
      if (!activity)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: TextField(
            controller: search,
            onSubmitted: (_) {
              offset = 0;
              load();
            },
            decoration: InputDecoration(
              labelText: tr('searchUsers'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: busy
                    ? null
                    : () {
                        offset = 0;
                        load();
                      },
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
        ),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            error!,
            style: const TextStyle(color: Colors.orangeAccent),
          ),
        ),
      if (!busy && (activity ? events : users).isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(tr('noAccountsFound')),
        ),
      if (!activity)
        ...users.map((u) {
          final self = u['id'] == widget.api.account?['id'];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${u['email']}${self ? ' · ${tr('yourAccount')}' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        label: Text(
                          tr(
                            u['active'] == true
                                ? 'accountActive'
                                : 'accountInactive',
                          ),
                        ),
                      ),
                      DropdownButton<String>(
                        value: u['role'],
                        items: ['member', 'admin']
                            .map(
                              (r) => DropdownMenuItem(
                                value: r,
                                child: Text(tr(r)),
                              ),
                            )
                            .toList(),
                        onChanged: busy || self
                            ? null
                            : (v) {
                                if (v != u['role']) update(u, role: v);
                              },
                      ),
                      OutlinedButton(
                        onPressed: busy || self
                            ? null
                            : () => update(u, active: u['active'] != true),
                        child: Text(
                          tr(
                            u['active'] == true
                                ? 'deactivateUser'
                                : 'activateUser',
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: busy || u['active'] != true
                            ? null
                            : () => recovery(u),
                        icon: const Icon(Icons.mail_outline),
                        label: Text(tr('sendRecoveryLink')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      if (activity)
        ...events.map(
          (e) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppStrings.of(context).label(e['kind'])),
                  Text(
                    '${e['email'] ?? e['user_id']} · ${DateTime.fromMillisecondsSinceEpoch((e['created_at'] * 1000).round()).toLocal()}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 16,
        children: [
          TextButton(
            onPressed: busy || offset == 0
                ? null
                : () {
                    offset -= 100;
                    load();
                  },
            child: Text(tr('previousPage')),
          ),
          TextButton(
            onPressed: busy || !more
                ? null
                : () {
                    offset += 100;
                    load();
                  },
            child: Text(tr('nextPage')),
          ),
        ],
      ),
    ],
  );
}
