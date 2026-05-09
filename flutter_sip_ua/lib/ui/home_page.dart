import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sip_providers.dart';
import '../sip/sip_user_agent.dart';
import 'call_page.dart';
import 'login_page.dart';
import 'widgets/buddy_sidebar.dart';
import 'widgets/buddy_stream.dart';
import 'widgets/dial_pad.dart';
import 'widgets/dialer_action_row.dart';
import 'widgets/welcome_pane.dart';

/// Browser-Phone style two-pane home: a buddy sidebar plus a content area
/// that shows either a welcome pane or the selected buddy's stream.
///
/// The dial pad and the SIP wire log are surfaced as overlays (a modal
/// sheet for the dialer; the log is opened in a full-screen route).
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const double _wideBreakpoint = 900;
  bool _restoreScheduled = false;
  bool _streamRoutePushed = false;

  @override
  Widget build(BuildContext context) {
    if (!_restoreScheduled) {
      _restoreScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAccount());
    }

    final reg =
        ref.watch(registrationStateProvider).value ??
        RegistrationState.unregistered;
    final account =
        ref.watch(accountProvider) ?? ref.read(sipUserAgentProvider).account;
    final selected = ref.watch(selectedBuddyProvider);
    final canCall = reg == RegistrationState.registered;
    final isWide = MediaQuery.of(context).size.width >= _wideBreakpoint;

    // Push the call page when a new call needs UI.
    ref.listen<AsyncValue<SipCall>>(callEventsProvider, (_, next) {
      next.whenData(_maybeNavigateToCall);
    });

    final sidebar = BuddySidebar(
      account: account,
      regState: reg,
      onOpenDialer: _openDialer,
      onOpenLog: _openLog,
      onEditAccount: _openLogin,
      onSignOut: _signOut,
    );

    if (isWide) {
      _streamRoutePushed = false;
      final content = selected == null
          ? WelcomePane(
              account: account,
              regState: reg,
              onOpenDialer: _openDialer,
              onOpenLog: _openLog,
            )
          : BuddyStream(
              key: ValueKey(selected),
              peer: selected,
              canCall: canCall,
              onCall: _placeCall,
            );
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              SizedBox(width: 320, child: sidebar),
              VerticalDivider(
                width: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: content),
            ],
          ),
        ),
      );
    }

    // Narrow layout: the sidebar fills the screen; selecting a buddy
    // pushes the stream as its own route so the system back gesture
    // clears the selection.
    if (selected != null && !_streamRoutePushed) {
      _streamRoutePushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final peer = selected;
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'stream'),
                builder: (_) => Scaffold(
                  body: SafeArea(
                    child: BuddyStream(
                      peer: peer,
                      canCall: canCall,
                      onCall: _placeCall,
                      onClose: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ),
            )
            .then((_) {
              if (!mounted) return;
              _streamRoutePushed = false;
              ref.read(selectedBuddyProvider.notifier).clear();
            });
      });
    }

    return Scaffold(body: SafeArea(child: sidebar));
  }

  // ---------------------------------------------------------------------------
  // Account lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _restoreAccount() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final account = readPersistedAccount(prefs);
    if (account == null) {
      _openLogin();
      return;
    }
    ref.read(accountProvider.notifier).set(account);
    await ref.read(sipUserAgentProvider).start(account);
  }

  Future<void> _openLogin() async {
    if (!mounted) return;
    final initial =
        ref.read(accountProvider) ?? ref.read(sipUserAgentProvider).account;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(
          initial: initial,
          onSubmit: (acc) async {
            final ua = ref.read(sipUserAgentProvider);
            final prefs = ref.read(sharedPreferencesProvider);
            await ua.start(acc);
            await persistAccount(prefs, acc);
            ref.read(accountProvider.notifier).set(acc);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
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
      await ref.read(sipUserAgentProvider).stop();
    } catch (_) {
      /* best-effort */
    }
    await clearPersistedAccount(ref.read(sharedPreferencesProvider));
    ref.read(accountProvider.notifier).set(null);
    ref.read(callsProvider.notifier).clear();
    ref.read(messagesProvider.notifier).clear();
    ref.read(unreadProvider.notifier).clearAll();
    ref.read(selectedBuddyProvider.notifier).clear();
    if (!mounted) return;
    _openLogin();
  }

  // ---------------------------------------------------------------------------
  // Calls
  // ---------------------------------------------------------------------------

  void _placeCall(String target) {
    final t = target.trim();
    if (t.isEmpty) return;
    if (!ref.read(isRegisteredProvider)) return;
    ref.read(sipUserAgentProvider).makeCall(t);
  }

  void _maybeNavigateToCall(SipCall call) {
    if (call.state != CallState.incomingRinging &&
        call.state != CallState.outgoingRinging &&
        call.state != CallState.active) {
      return;
    }
    if (ModalRoute.of(context)?.settings.name == 'call') return;
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'call'),
        builder: (_) => CallPage(callId: call.id),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialer overlay
  // ---------------------------------------------------------------------------

  Future<void> _openDialer() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              child: _DialerSheet(
                onCall: (target) {
                  Navigator.of(ctx).pop();
                  _placeCall(target);
                },
                onMessage: (target, body) {
                  Navigator.of(ctx).pop();
                  ref.read(sipUserAgentProvider).sendMessage(target, body);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Log overlay
  // ---------------------------------------------------------------------------

  void _openLog() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const _LogPage()));
  }
}

// ---------------------------------------------------------------------------
// Dialer sheet
// ---------------------------------------------------------------------------

/// Browser-Phone style dialer:
///   * The typed digits live in [dialerInputProvider] so the sheet
///     can be dismissed and reopened (or have its number pre-populated
///     from a buddy tile) without losing state.
///   * A bottom action row offers Video / Audio / Message instead of a
///     single dial button.
class _DialerSheet extends ConsumerStatefulWidget {
  const _DialerSheet({required this.onCall, required this.onMessage});

  final void Function(String target) onCall;
  final void Function(String target, String body) onMessage;

  @override
  ConsumerState<_DialerSheet> createState() => _DialerSheetState();
}

class _DialerSheetState extends ConsumerState<_DialerSheet> {
  late final TextEditingController _dial;

  @override
  void initState() {
    super.initState();
    _dial = TextEditingController(text: ref.read(dialerInputProvider));
  }

  @override
  void dispose() {
    _dial.dispose();
    super.dispose();
  }

  void _setText(String value) {
    _dial.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    ref.read(dialerInputProvider.notifier).set(value);
  }

  void _append(String d) {
    final c = _dial;
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
    ref.read(dialerInputProvider.notifier).set(c.text);
  }

  void _backspace() {
    final c = _dial;
    if (c.text.isEmpty) return;
    final sel = c.selection;
    if (sel.isValid && sel.start > 0 && sel.start == sel.end) {
      final start = sel.start;
      c.value = TextEditingValue(
        text: c.text.replaceRange(start - 1, start, ''),
        selection: TextSelection.collapsed(offset: start - 1),
      );
    } else if (sel.isValid && sel.start != sel.end) {
      c.value = TextEditingValue(
        text: c.text.replaceRange(sel.start, sel.end, ''),
        selection: TextSelection.collapsed(offset: sel.start),
      );
    } else {
      c.text = c.text.substring(0, c.text.length - 1);
    }
    ref.read(dialerInputProvider.notifier).set(c.text);
  }

  Future<void> _composeMessage() async {
    final target = _dial.text.trim();
    if (target.isEmpty) return;
    final body = await _MessageComposeSheet.show(context, target: target);
    if (body == null || body.isEmpty) return;
    widget.onMessage(target, body);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCall = ref.watch(isRegisteredProvider);
    final dialed = ref.watch(dialerInputProvider);
    // Keep the controller in sync if the provider was changed externally
    // (e.g. by selecting a buddy and pressing "Call back").
    if (dialed != _dial.text) {
      _dial.value = TextEditingValue(
        text: dialed,
        selection: TextSelection.collapsed(offset: dialed.length),
      );
    }
    final ready = canCall && dialed.trim().isNotEmpty;
    return Padding(
      // BP `.dialCall` block sits in a 25 px gutter; we honour that with
      // a generous outer padding (more on the bottom so the action row
      // breathes against the sheet edge).
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _dial,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2,
                  ),
                  // Browser-Phone `.dialTextInput` keeps a 1px bottom
                  // underline that thickens to #333 on focus.
                  decoration: InputDecoration(
                    hintText: 'Extension or sip:',
                    filled: false,
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF555555)
                            : const Color(0xFFCCCCCC),
                      ),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFFCCCCCC)
                            : const Color(0xFF333333),
                        width: 1.5,
                      ),
                    ),
                  ),
                  onChanged: (v) =>
                      ref.read(dialerInputProvider.notifier).set(v),
                ),
              ),
              IconButton(
                tooltip: 'Backspace',
                onPressed: dialed.isEmpty ? null : _backspace,
                onLongPress: dialed.isEmpty ? null : () => _setText(''),
                icon: const Icon(Icons.backspace_outlined),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DialPad(onKey: _append, onLongZero: () => _append('+')),
          // The action row carries its own 18 px of vertical padding to
          // mirror BP `.dialCall { padding: 25px; margin-top: 10px }`,
          // so we don't need an extra SizedBox here.
          DialerActionRow(
            enabled: ready,
            onAudioCall: () => widget.onCall(_dial.text.trim()),
            onMessage: _composeMessage,
          ),
        ],
      ),
    );
  }
}

/// Tiny modal for composing a one-shot SIP MESSAGE from the dialer.
class _MessageComposeSheet extends StatefulWidget {
  const _MessageComposeSheet({required this.target});
  final String target;

  static Future<String?> show(BuildContext context, {required String target}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _MessageComposeSheet(target: target),
      ),
    );
  }

  @override
  State<_MessageComposeSheet> createState() => _MessageComposeSheetState();
}

class _MessageComposeSheetState extends State<_MessageComposeSheet> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets + 20, top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Message ${widget.target}',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Type your message…',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    final body = _ctl.text.trim();
                    if (body.isEmpty) return;
                    Navigator.of(context).pop(body);
                  },
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Log page
// ---------------------------------------------------------------------------

class _LogPage extends ConsumerWidget {
  const _LogPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final log = ref.watch(logsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('SIP wire log · ${log.length}'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            onPressed: log.isEmpty
                ? null
                : () {
                    Clipboard.setData(
                      ClipboardData(text: log.reversed.join('\n')),
                    );
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Log copied')));
                  },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: log.isEmpty
                ? null
                : () => ref.read(logsProvider.notifier).clear(),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: log.isEmpty
          ? Center(
              child: Text(
                'Log is empty',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
    );
  }
}
