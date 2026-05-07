import 'package:flutter/material.dart';

import '../sip/sip_user_agent.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.initial, required this.onSubmit});

  final SipAccount? initial;
  final Future<void> Function(SipAccount account) onSubmit;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _serverUri;
  late final TextEditingController _domain;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _displayName;
  late final TextEditingController _sessionExpires;
  late final TextEditingController _minSE;
  final _form = GlobalKey<FormState>();

  bool _showPassword = false;
  bool _showAdvanced = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _serverUri = TextEditingController(
      text: i?.serverUri.toString() ?? 'ws://10.100.53.104:8088',
    );
    _domain = TextEditingController(text: i?.domain ?? 'pbx.local');
    _username = TextEditingController(text: i?.username ?? '6001');
    _password = TextEditingController(text: i?.password ?? '');
    _displayName = TextEditingController(text: i?.displayName ?? '');
    _sessionExpires = TextEditingController(
      text: '${i?.sessionExpires ?? 1800}',
    );
    _minSE = TextEditingController(text: '${i?.minSE ?? 90}');
  }

  @override
  void dispose() {
    _serverUri.dispose();
    _domain.dispose();
    _username.dispose();
    _password.dispose();
    _displayName.dispose();
    _sessionExpires.dispose();
    _minSE.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_form.currentState?.validate() != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uri = Uri.parse(_serverUri.text.trim());
      const allowed = {'ws', 'wss', 'sip'};
      if (!allowed.contains(uri.scheme.toLowerCase())) {
        throw const FormatException(
          'Server URI must start with ws://, wss:// or sip:',
        );
      }
      final account = SipAccount(
        username: _username.text.trim(),
        password: _password.text,
        domain: _domain.text.trim(),
        serverUri: uri,
        displayName: _displayName.text.trim().isEmpty
            ? null
            : _displayName.text.trim(),
        sessionExpires: int.tryParse(_sessionExpires.text.trim()) ?? 1800,
        minSE: int.tryParse(_minSE.text.trim()) ?? 90,
      );
      await widget.onSubmit(account);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SIP account'),
        leading: Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.call,
                        color: scheme.onPrimaryContainer,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Sign in to your SIP account',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Enter the credentials provided by your administrator.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _serverUri,
                            decoration: const InputDecoration(
                              labelText: 'Server URI',
                              prefixIcon: Icon(Icons.dns_outlined),
                              helperText:
                                  'ws://host:8088 · wss://host:8089 · sip:host:5060',
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Required'
                                : null,
                            autocorrect: false,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _domain,
                            decoration: const InputDecoration(
                              labelText: 'SIP domain / realm',
                              prefixIcon: Icon(Icons.domain_outlined),
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Required'
                                : null,
                            autocorrect: false,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _username,
                            decoration: const InputDecoration(
                              labelText: 'Username (extension)',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Required'
                                : null,
                            autocorrect: false,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _password,
                            obscureText: !_showPassword,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                tooltip: _showPassword ? 'Hide' : 'Show',
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                                onPressed: () => setState(
                                  () => _showPassword = !_showPassword,
                                ),
                              ),
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? 'Required' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _displayName,
                            decoration: const InputDecoration(
                              labelText: 'Display name (optional)',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          16,
                        ),
                        leading: const Icon(Icons.tune_outlined),
                        title: const Text('Advanced'),
                        subtitle: const Text(
                          'RFC 4028 session timer parameters',
                        ),
                        initiallyExpanded: _showAdvanced,
                        onExpansionChanged: (v) =>
                            setState(() => _showAdvanced = v),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _sessionExpires,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Session-Expires (s)',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _minSE,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Min-SE (s)',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: scheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(color: scheme.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(_busy ? 'Connecting…' : 'Register'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
