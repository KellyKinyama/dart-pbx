import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sip/sip_user_agent.dart';
import 'call_page.dart';
import 'login_page.dart';
import 'widgets/dial_pad.dart';
import 'widgets/status_chip.dart';

const _prefsKey = 'sip_account_v1';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.ua, required this.prefs});
  final SipUserAgent ua;
  final SharedPreferences prefs;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  RegistrationState _reg = RegistrationState.unregistered;
  final List<String> _log = [];
  final List<SipTextMessage> _messages = [];
  final List<SipCall> _recents = [];
  final Set<String> _everActive = <String>{};

  int _tab = 0;
  final TextEditingController _dial = TextEditingController();

  StreamSubscription<RegistrationState>? _regSub;
  StreamSubscription<SipCall>? _callSub;
  StreamSubscription<SipTextMessage>? _msgsSub;
  StreamSubscription<String>? _logSub;

  @override
  void initState() {
    super.initState();
    _regSub = widget.ua.registrationStream.listen(
      (s) => setState(() => _reg = s),
    );
    _callSub = widget.ua.callStream.listen(_onCall);
    _msgsSub = widget.ua.messageStream.listen(
      (m) => setState(() => _messages.insert(0, m)),
    );
    _logSub = widget.ua.logStream.listen((l) {
      setState(() {
        _log.insert(0, l);
        if (_log.length > 500) _log.removeLast();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAccount());
  }

  @override
  void dispose() {
    _regSub?.cancel();
    _callSub?.cancel();
    _msgsSub?.cancel();
    _logSub?.cancel();
    _dial.dispose();
    super.dispose();
  }

  Future<void> _restoreAccount() async {
    final raw = widget.prefs.getString(_prefsKey);
    if (raw == null) {
      _openLogin();
      return;
    }
    final parts = raw.split('|');
    if (parts.length < 4) {
      _openLogin();
      return;
    }
    final account = SipAccount(
      serverUri: Uri.parse(parts[0]),
      domain: parts[1],
      username: parts[2],
      password: parts[3],
      displayName: parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null,
      sessionExpires: parts.length > 5 ? int.tryParse(parts[5]) ?? 1800 : 1800,
      minSE: parts.length > 6 ? int.tryParse(parts[6]) ?? 90 : 90,
    );
    await widget.ua.start(account);
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This clears the saved account credentials and unregisters from the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.ua.stop();
    } catch (_) {
      /* best-effort */
    }
    await widget.prefs.remove(_prefsKey);
    if (!mounted) return;
    setState(() {
      _reg = RegistrationState.unregistered;
      _recents.clear();
      _everActive.clear();
      _messages.clear();
    });
    _openLogin();
  }

  Future<void> _openLogin() async {
    if (!mounted) return;
    final initial = widget.ua.account;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(
          initial: initial,
          onSubmit: (acc) async {
            await widget.ua.start(acc);
            await widget.prefs.setString(
              _prefsKey,
              [
                acc.serverUri.toString(),
                acc.domain,
                acc.username,
                acc.password,
                acc.displayName ?? '',
                '${acc.sessionExpires}',
                '${acc.minSE}',
              ].join('|'),
            );
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _onCall(SipCall call) {
    setState(() {
      if (call.state == CallState.active) _everActive.add(call.id);
      _recents.removeWhere((c) => c.id == call.id);
      _recents.insert(0, call);
      if (_recents.length > 50) {
        final removed = _recents.removeLast();
        _everActive.remove(removed.id);
      }
    });
    if (call.state == CallState.incomingRinging ||
        call.state == CallState.outgoingRinging ||
        call.state == CallState.active) {
      if (ModalRoute.of(context)?.settings.name != 'call') {
        Navigator.of(context).push(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'call'),
            builder: (_) => CallPage(ua: widget.ua, callId: call.id),
          ),
        );
      }
    }
  }

  void _placeCall([String? target]) {
    final t = (target ?? _dial.text).trim();
    if (t.isEmpty) return;
    if (_reg != RegistrationState.registered) return;
    widget.ua.makeCall(t);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _DialTab(
        controller: _dial,
        canCall: _reg == RegistrationState.registered,
        onCall: () => _placeCall(),
      ),
      _RecentsTab(
        recents: _recents,
        everActive: _everActive,
        canCall: _reg == RegistrationState.registered,
        onCall: _placeCall,
      ),
      _MessagesTab(
        ua: widget.ua,
        messages: _messages,
        canSend: _reg == RegistrationState.registered,
      ),
      _LogTab(log: _log, onClear: () => setState(() => _log.clear())),
    ];
    final titles = const ['Keypad', 'Recents', 'Messages', 'Log'];

    return Scaffold(
      appBar: AppBar(
        title: _AccountTitle(
          account: widget.ua.account,
          fallback: titles[_tab],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: RegistrationStatusChip(state: _reg),
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: const Icon(Icons.manage_accounts_outlined),
            onSelected: (v) {
              switch (v) {
                case 'edit':
                  _openLogin();
                  break;
                case 'signout':
                  _signOut();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit account')),
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(key: ValueKey(_tab), child: pages[_tab]),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dialpad_outlined),
            selectedIcon: Icon(Icons.dialpad),
            label: 'Keypad',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'Recents',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Messages',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Log',
          ),
        ],
      ),
    );
  }
}

class _AccountTitle extends StatelessWidget {
  const _AccountTitle({required this.account, required this.fallback});
  final SipAccount? account;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (account == null) {
      return Text(fallback, style: theme.textTheme.titleLarge);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          account!.displayName?.isNotEmpty == true
              ? account!.displayName!
              : account!.username,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          account!.aor,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Keypad tab
// ---------------------------------------------------------------------------

class _DialTab extends StatefulWidget {
  const _DialTab({
    required this.controller,
    required this.canCall,
    required this.onCall,
  });
  final TextEditingController controller;
  final bool canCall;
  final VoidCallback onCall;

  @override
  State<_DialTab> createState() => _DialTabState();
}

class _DialTabState extends State<_DialTab> {
  void _append(String d) {
    final c = widget.controller;
    final sel = c.selection;
    if (sel.isValid && sel.start >= 0) {
      final newText = c.text.replaceRange(sel.start, sel.end, d);
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + d.length),
      );
    } else {
      c.text += d;
    }
    setState(() {});
  }

  void _backspace() {
    final c = widget.controller;
    if (c.text.isEmpty) return;
    final sel = c.selection;
    if (sel.isValid && sel.start > 0) {
      final start = sel.start;
      final end = sel.end;
      if (start == end) {
        final newText = c.text.replaceRange(start - 1, end, '');
        c.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start - 1),
        );
      } else {
        final newText = c.text.replaceRange(start, end, '');
        c.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start),
        );
      }
    } else {
      c.text = c.text.substring(0, c.text.length - 1);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.2,
                      ),
                      keyboardType: TextInputType.text,
                      decoration: const InputDecoration(
                        hintText: 'Extension or sip:',
                        border: InputBorder.none,
                        filled: false,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Backspace',
                    onPressed: widget.controller.text.isEmpty
                        ? null
                        : _backspace,
                    onLongPress: () {
                      widget.controller.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.backspace_outlined),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          DialPad(onKey: _append, onLongZero: () => _append('+')),
          const SizedBox(height: 16),
          Row(
            children: [
              const Spacer(),
              SizedBox(
                width: 72,
                height: 72,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.canCall
                        ? Colors.green.shade600
                        : theme.disabledColor,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: widget.canCall ? widget.onCall : null,
                  child: const Icon(Icons.call, size: 32),
                ),
              ),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recents tab
// ---------------------------------------------------------------------------

class _RecentsTab extends StatelessWidget {
  const _RecentsTab({
    required this.recents,
    required this.everActive,
    required this.canCall,
    required this.onCall,
  });
  final List<SipCall> recents;
  final Set<String> everActive;
  final bool canCall;
  final void Function(String party) onCall;

  @override
  Widget build(BuildContext context) {
    if (recents.isEmpty) {
      return const _EmptyState(
        icon: Icons.history,
        title: 'No recent calls',
        subtitle: 'Calls you make or receive will appear here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: recents.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (_, i) {
        final c = recents[i];
        final outgoing = c.outgoing;
        // A call is "missed" only if it was inbound, ended, and never
        // reached the active state (i.e. the user never picked up).
        final missed =
            !outgoing &&
            c.state == CallState.ended &&
            !everActive.contains(c.id);
        final color = missed
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.onSurface;
        final icon = outgoing
            ? Icons.call_made
            : (missed ? Icons.call_missed : Icons.call_received);
        return ListTile(
          leading: PartyAvatar(party: c.remoteParty),
          title: Text(
            _short(c.remoteParty),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontWeight: FontWeight.w500),
          ),
          subtitle: Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                _formatWhen(c.startedAt) +
                    (c.state == CallState.active ? ' · in call' : ''),
                style: TextStyle(color: color.withValues(alpha: 0.7)),
              ),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.call_outlined),
            onPressed: canCall ? () => onCall(c.remoteParty) : null,
          ),
          onTap: canCall ? () => onCall(c.remoteParty) : null,
        );
      },
    );
  }

  static String _short(String party) {
    var s = party;
    if (s.startsWith('sip:')) s = s.substring(4);
    return s;
  }

  static String _formatWhen(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

// ---------------------------------------------------------------------------
// Messages tab
// ---------------------------------------------------------------------------

class _MessagesTab extends StatefulWidget {
  const _MessagesTab({
    required this.ua,
    required this.messages,
    required this.canSend,
  });
  final SipUserAgent ua;
  final List<SipTextMessage> messages;
  final bool canSend;

  @override
  State<_MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<_MessagesTab> {
  final TextEditingController _to = TextEditingController(text: '6002');
  final TextEditingController _body = TextEditingController();

  @override
  void dispose() {
    _to.dispose();
    _body.dispose();
    super.dispose();
  }

  void _send() {
    final to = _to.text.trim();
    final text = _body.text;
    if (to.isEmpty || text.isEmpty) return;
    widget.ua.sendMessage(to, text);
    _body.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: widget.messages.isEmpty
              ? const _EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'No messages yet',
                  subtitle: 'Inbound SIP MESSAGEs will appear here.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: widget.messages.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final m = widget.messages[i];
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.8,
                        ),
                        child: Card(
                          color: theme.colorScheme.secondaryContainer,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.from,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme
                                        .colorScheme
                                        .onSecondaryContainer
                                        .withValues(alpha: 0.7),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  m.body,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            children: [
              TextField(
                controller: _to,
                decoration: const InputDecoration(
                  labelText: 'To',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _body,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Type a message',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: widget.canSend ? _send : null,
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Log tab
// ---------------------------------------------------------------------------

class _LogTab extends StatelessWidget {
  const _LogTab({required this.log, required this.onClear});
  final List<String> log;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Text(
                '${log.length} entries',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Copy all',
                onPressed: log.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(
                          ClipboardData(text: log.reversed.join('\n')),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Log copied')),
                        );
                      },
                icon: const Icon(Icons.copy_all_outlined),
              ),
              IconButton(
                tooltip: 'Clear',
                onPressed: log.isEmpty ? null : onClear,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: log.isEmpty
              ? const _EmptyState(
                  icon: Icons.terminal,
                  title: 'Log is empty',
                  subtitle: 'SIP signalling output will be shown here.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: log.length,
                  itemBuilder: (_, i) => SelectableText(
                    log[i],
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
