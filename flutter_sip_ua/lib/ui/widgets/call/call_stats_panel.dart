import 'package:flutter/material.dart';

import '../../bp_palette.dart';

/// Compact "stats" overlay that BP renders next to the avatar during a
/// call. Pure presentational — fed by the orchestrator with whatever
/// values the SIP UA exposes (or `null` to render a dash).
class CallStatsPanel extends StatelessWidget {
  const CallStatsPanel({
    super.key,
    required this.codec,
    required this.bitrateKbps,
    required this.packetLossPct,
    required this.jitterMs,
    required this.rttMs,
  });

  final String? codec;
  final double? bitrateKbps;
  final double? packetLossPct;
  final double? jitterMs;
  final double? rttMs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;

    Color qualityColor() {
      final loss = packetLossPct ?? 0;
      if (loss > 5) return bp.hangup;
      if (loss > 1) return bp.presenceRinging;
      return bp.activeCall;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.signal_cellular_alt, size: 18, color: qualityColor()),
              const SizedBox(width: 6),
              Text(
                'Call quality',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _kv('Codec', codec ?? '—'),
              _kv('Bitrate', _fmt(bitrateKbps, 'kbps')),
              _kv('Loss', _fmt(packetLossPct, '%')),
              _kv('Jitter', _fmt(jitterMs, 'ms')),
              _kv('RTT', _fmt(rttMs, 'ms')),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(double? v, String unit) {
    if (v == null) return '—';
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} $unit';
  }

  Widget _kv(String label, String value) {
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        );
      },
    );
  }
}
