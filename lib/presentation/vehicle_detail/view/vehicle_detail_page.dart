/// Feature B — the readings register and SOC history.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/fleet_view.dart';
import '../../../domain/entities/verdict.dart';
import '../../common/formatting.dart';
import '../../common/pills.dart';
import '../bloc/vehicle_detail_bloc.dart';

class VehicleDetailPage extends StatelessWidget {
  const VehicleDetailPage({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<VehicleDetailBloc, VehicleDetailState>(
        builder: (context, state) => Scaffold(
          appBar: AppBar(
            title: Text(state.detail?.regNumber ?? 'Vehicle'),
            actions: [
              if (state.detail != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: StatusChip(status: state.detail!.status),
                  ),
                ),
            ],
          ),
          body: switch (state.status) {
            DetailStatus.initial ||
            DetailStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            DetailStatus.notFound => const Center(
              child: Text('That vehicle is not in the fleet register.'),
            ),
            DetailStatus.failed => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(state.error ?? 'Unknown error'),
              ),
            ),
            DetailStatus.ready => _Body(state: state),
          },
        ),
      );
}

class _Body extends StatelessWidget {
  const _Body({required this.state});

  final VehicleDetailState state;

  @override
  Widget build(BuildContext context) {
    final detail = state.detail!;

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            detail.model,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ),
        const SizedBox(height: 8),
        const _SectionHeader('Readings'),
        // One row per signal, in a fixed order, including signals that have
        // never reported. Each carries its own age — deliberately independent
        // of the vehicle-level freshness driving the status chip above, which
        // is why a MOVING vehicle can legitimately show a STALE reading here.
        for (final row in detail.register) _RegisterTile(row: row),
        const SizedBox(height: 16),
        const _SectionHeader('State of charge'),
        _SocHistory(samples: state.socHistory),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Color(0xFF6B7280),
      ),
    ),
  );
}

class _RegisterTile extends StatelessWidget {
  const _RegisterTile({required this.row});

  final RegisterRow row;

  @override
  Widget build(BuildContext context) {
    final absent = row.verdict == Verdict.neverReported;

    return ListTile(
      dense: true,
      title: Text(signalLabel(row.kind), style: const TextStyle(fontSize: 14)),
      subtitle: row.age == null
          ? const Text(
              'never reported',
              style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
            )
          : Text(
              formatAge(row.age!),
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatSignalValue(row.kind, row.value),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: absent || row.verdict == Verdict.stale
                  ? const Color(0xFF9CA3AF)
                  : Theme.of(context).colorScheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          // Wide enough for the longest label. Found by looking at the app:
          // at 58 the word NORMAL wrapped to "NORMA / L".
          SizedBox(width: 72, child: VerdictPill(verdict: row.verdict)),
        ],
      ),
    );
  }
}

/// A sparkline over the retained window.
///
/// Hand-drawn on a canvas rather than pulling in a charting package: this is
/// one series with no interaction, and a dependency would be a lot of surface
/// area for a polyline.
class _SocHistory extends StatelessWidget {
  const _SocHistory({required this.samples});

  final List<SocSample> samples;

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Text(
          'Not enough history yet to draw a line.',
          style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
        ),
      );
    }

    final first = samples.first;
    final last = samples.last;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 96,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(
                samples: samples,
                colour: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${first.value.round()}%',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
              Text(
                '${samples.length} points',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
              Text(
                '${last.value.round()}%',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.samples, required this.colour});

  final List<SocSample> samples;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    // SOC is a percentage, so the axis is fixed at 0..100 rather than scaled to
    // the data. An auto-scaled axis turns a 3% wobble into a dramatic cliff,
    // which is exactly the wrong impression on a battery chart.
    const minY = 0.0;
    const maxY = 100.0;

    final firstMs = samples.first.eventTs.millisecondsSinceEpoch;
    final spanMs = samples.last.eventTs.millisecondsSinceEpoch - firstMs;

    Offset pointFor(SocSample s) {
      final x = spanMs == 0
          ? 0.0
          : (s.eventTs.millisecondsSinceEpoch - firstMs) / spanMs * size.width;
      final y = size.height -
          ((s.value - minY) / (maxY - minY)).clamp(0.0, 1.0) * size.height;
      return Offset(x, y);
    }

    final path = Path()..moveTo(pointFor(samples.first).dx, pointFor(samples.first).dy);
    for (final sample in samples.skip(1)) {
      final p = pointFor(sample);
      path.lineTo(p.dx, p.dy);
    }

    // The 20% warning line, so the series is readable against the threshold
    // that actually matters rather than against nothing.
    final thresholdY = size.height - (20.0 / 100.0) * size.height;
    canvas.drawLine(
      Offset(0, thresholdY),
      Offset(size.width, thresholdY),
      Paint()
        ..color = const Color(0xFFB26A00).withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.colour != colour;
}
