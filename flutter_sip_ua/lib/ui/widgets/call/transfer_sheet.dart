import 'package:flutter/material.dart';

/// Result of a transfer dialog: the SIP target plus how to transfer.
class TransferRequest {
  const TransferRequest({required this.target, required this.attended});

  final String target;

  /// `true` ⇒ Attended (consultation) transfer, the user wants to talk
  /// to the destination first.
  /// `false` ⇒ Blind transfer, REFER the call straight through.
  final bool attended;
}

/// Browser-Phone style transfer bottom sheet. Asks for a destination
/// extension/URI and lets the user pick Blind or Attended.
class TransferSheet extends StatefulWidget {
  const TransferSheet({super.key});

  static Future<TransferRequest?> show(BuildContext context) {
    return showModalBottomSheet<TransferRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: TransferSheet(),
      ),
    );
  }

  @override
  State<TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends State<TransferSheet> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit({required bool attended}) {
    final t = _ctl.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop(TransferRequest(target: t, attended: attended));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets + 24, top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Transfer call',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Destination',
              hintText: 'extension or sip:user@host',
              prefixIcon: Icon(Icons.phone_forwarded),
            ),
            onSubmitted: (_) => _submit(attended: false),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _submit(attended: true),
                  icon: const Icon(Icons.group_add),
                  label: const Text('Attended'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  onPressed: () => _submit(attended: false),
                  icon: const Icon(Icons.send),
                  label: const Text('Blind'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
