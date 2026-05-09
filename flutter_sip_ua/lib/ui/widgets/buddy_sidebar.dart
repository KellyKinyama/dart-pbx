import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/sip_providers.dart';
import '../../sip/sip_user_agent.dart';
import '../bp_palette.dart';
import 'status_chip.dart';

/// Browser-Phone style left rail: account header, search, buddy list and a
/// bottom toolbar with quick actions (dial, log, sign out).
class BuddySidebar extends ConsumerStatefulWidget {
  const BuddySidebar({
    super.key,
    required this.account,
    required this.regState,
    required this.onOpenDialer,
    required this.onOpenLog,
    required this.onEditAccount,
    required this.onSignOut,
    this.onBuddyTap,
  });

  final SipAccount? account;
  final RegistrationState regState;
  final VoidCallback onOpenDialer;
  final VoidCallback onOpenLog;
  final VoidCallback onEditAccount;
  final VoidCallback onSignOut;

  /// Optional notification fired after a buddy is selected; lets the parent
  /// close a navigation drawer on small screens.
  final VoidCallback? onBuddyTap;

  @override
  ConsumerState<BuddySidebar> createState() => _BuddySidebarState();
}

class _BuddySidebarState extends ConsumerState<BuddySidebar> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = ref.watch(selectedBuddyProvider);
    final buddies = ref.watch(buddiesProvider);
    final query = _search.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? buddies
        : buddies
              .where(
                (b) =>
                    b.peer.toLowerCase().contains(query) ||
                    b.displayName.toLowerCase().contains(query),
              )
              .toList();

    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          _AccountHeader(
            account: widget.account,
            regState: widget.regState,
            onEdit: widget.onEditAccount,
            onSignOut: widget.onSignOut,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search buddies',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? _EmptyBuddyList(hasQuery: query.isNotEmpty)
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final b = filtered[i];
                      final isActive = selected != null && b.peer == selected;
                      final lineState = ref.watch(
                        peerLineStateProvider(b.peer),
                      );
                      return _BuddyTile(
                        buddy: b,
                        selected: isActive,
                        lineState: lineState,
                        onTap: () {
                          ref
                              .read(selectedBuddyProvider.notifier)
                              .select(b.peer);
                          ref.read(unreadProvider.notifier).clearFor(b.peer);
                          widget.onBuddyTap?.call();
                        },
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          _SidebarToolbar(onDial: widget.onOpenDialer, onLog: widget.onOpenLog),
        ],
      ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({
    required this.account,
    required this.regState,
    required this.onEdit,
    required this.onSignOut,
  });
  final SipAccount? account;
  final RegistrationState regState;
  final VoidCallback onEdit;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = account?.displayName?.isNotEmpty == true
        ? account!.displayName!
        : (account?.username ?? 'Not signed in');
    final aor = account?.aor ?? '—';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: [
          PartyAvatar(party: account?.aor ?? '?', size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  aor,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                RegistrationStatusChip(state: regState),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'edit':
                  onEdit();
                  break;
                case 'signout':
                  onSignOut();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.manage_accounts_outlined),
                  title: Text('Edit account'),
                ),
              ),
              PopupMenuItem(
                value: 'signout',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout),
                  title: Text('Sign out'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BuddyTile extends StatelessWidget {
  const _BuddyTile({
    required this.buddy,
    required this.selected,
    required this.lineState,
    required this.onTap,
  });
  final Buddy buddy;
  final bool selected;
  final BuddyLineState lineState;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bp = theme.bp;
    final preview = _previewLine(buddy);

    // Mirror the Browser-Phone CSS:
    //   .buddy           transparent left border
    //   .buddySelected   blue (#3478f3) left border
    //   .buddyActiveCall green (#40bd3f) left border + tinted bg
    //   .buddyActiveCallHollding grey (#999) left border + tinted bg
    final Color borderColor;
    final Color rowBg;
    final Color titleColor;
    switch (lineState) {
      case BuddyLineState.inCall:
        borderColor = bp.activeCall;
        rowBg = bp.buddyActive;
        titleColor = scheme.onSurface;
        break;
      case BuddyLineState.onHold:
        borderColor = bp.holdingCall;
        rowBg = bp.buddyHold;
        titleColor = scheme.onSurfaceVariant;
        break;
      case BuddyLineState.ringing:
        borderColor = bp.presenceRinging;
        rowBg = selected ? bp.buddySelected : Colors.transparent;
        titleColor = scheme.onSurface;
        break;
      case BuddyLineState.idle:
        borderColor = selected ? scheme.primary : Colors.transparent;
        rowBg = selected ? bp.buddySelected : Colors.transparent;
        titleColor = scheme.onSurface;
        break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 1, 6, 2),
      child: Material(
        color: rowBg,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: borderColor, width: 3)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AvatarWithPresence(
                  party: buddy.peer,
                  size: 38,
                  state: lineState,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              buddy.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: titleColor,
                              ),
                            ),
                          ),
                          Text(
                            _formatTimestamp(buddy.lastActivity),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (buddy.unread > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: BPColors.hangup,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                buddy.unread > 99 ? '99+' : '${buddy.unread}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _previewLine(Buddy b) {
    final m = b.lastMessage;
    if (m != null) {
      final prefix = m.outgoing ? 'You: ' : '';
      return '$prefix${m.body.replaceAll('\n', ' ')}';
    }
    final c = b.lastCall;
    if (c != null) {
      if (c.outgoing) return 'Outgoing call';
      return c.startedAt != null ? 'Incoming call' : 'Missed call';
    }
    return '';
  }

  static String _formatTimestamp(DateTime t) {
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inSeconds < 60) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

class _SidebarToolbar extends ConsumerWidget {
  const _SidebarToolbar({required this.onDial, required this.onLog});
  final VoidCallback onDial;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final mode = ref.watch(themeModeProvider);
    final (themeIcon, themeTooltip) = switch (mode) {
      ThemeMode.system => (
        Icons.brightness_auto,
        'Theme: system (tap to switch)',
      ),
      ThemeMode.light => (Icons.light_mode, 'Theme: light (tap to switch)'),
      ThemeMode.dark => (Icons.dark_mode, 'Theme: dark (tap to switch)'),
    };
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Open dialer',
            onPressed: onDial,
            icon: const Icon(Icons.dialpad),
            color: scheme.primary,
          ),
          IconButton(
            tooltip: 'SIP wire log',
            onPressed: onLog,
            icon: const Icon(Icons.terminal),
            color: scheme.primary,
          ),
          const Spacer(),
          IconButton(
            tooltip: themeTooltip,
            onPressed: () => ref.read(themeModeProvider.notifier).cycle(),
            icon: Icon(themeIcon),
            color: scheme.primary,
          ),
        ],
      ),
    );
  }
}

/// Avatar with a small presence pip in the lower-right corner that
/// reproduces Browser-Phone's `.dotOnline / .dotRinging / .dotInUse`
/// indicators next to each contact.
class _AvatarWithPresence extends StatelessWidget {
  const _AvatarWithPresence({
    required this.party,
    required this.size,
    required this.state,
  });
  final String party;
  final double size;
  final BuddyLineState state;

  @override
  Widget build(BuildContext context) {
    final bp = Theme.of(context).bp;
    final scheme = Theme.of(context).colorScheme;
    final Color dot;
    switch (state) {
      case BuddyLineState.inCall:
        dot = bp.presenceInUse;
        break;
      case BuddyLineState.onHold:
        dot = bp.presenceOnHold;
        break;
      case BuddyLineState.ringing:
        dot = bp.presenceRinging;
        break;
      case BuddyLineState.idle:
        dot = bp.presenceOnline;
        break;
    }
    final pip = (size * 0.32).clamp(10.0, 14.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PartyAvatar(party: party, size: size),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: pip,
              height: pip,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBuddyList extends StatelessWidget {
  const _EmptyBuddyList({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.contacts_outlined,
              size: 36,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              hasQuery ? 'No matches' : 'No buddies yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              hasQuery
                  ? 'Try a different search.'
                  : 'Calls and messages will appear here.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
