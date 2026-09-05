/// The status chip and the verdict pill.
library;

import 'package:flutter/material.dart';

import '../../domain/entities/vehicle_status.dart';
import '../../domain/entities/verdict.dart';
import 'formatting.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({required this.status, super.key});

  final VehicleStatus status;

  @override
  Widget build(BuildContext context) {
    final colour = statusColour(status, Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
      ),
      child: Text(
        statusLabel(status).toUpperCase(),
        style: TextStyle(
          color: colour,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// The verdict pill for one signal.
///
/// Renders nothing at all for [Verdict.neverReported] — the brief asks for "—"
/// with *no pill*, and an empty grey pill would read as a fourth state rather
/// than as absence.
class VerdictPill extends StatelessWidget {
  const VerdictPill({required this.verdict, super.key});

  final Verdict verdict;

  @override
  Widget build(BuildContext context) {
    if (!verdict.hasPill) return const SizedBox.shrink();

    final colour = verdictColour(verdict);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        verdictLabel(verdict),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: colour,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The alert badge on a fleet row.
class AlertBadge extends StatelessWidget {
  const AlertBadge({required this.count, required this.critical, super.key});

  final int count;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();

    final colour = critical
        ? const Color(0xFFB3261E)
        : const Color(0xFFB26A00);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            critical ? Icons.error : Icons.warning_amber_rounded,
            size: 12,
            color: Colors.white,
          ),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
