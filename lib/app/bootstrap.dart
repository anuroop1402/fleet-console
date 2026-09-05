/// Opens the database behind a visible loading state, and times it.
///
/// Startup is a first-class screen here, not an afterthought. Opening an
/// embedded database with a write-ahead log to replay is genuinely slow enough
/// to see, so the user gets a progress indicator rather than a white rectangle,
/// and the app gets a real error screen if the database will not open at all —
/// which on a local-first app is the difference between "unusable" and
/// "unusable with no explanation".
library;

import 'package:flutter/material.dart';

import 'di.dart';

/// How long each stage of startup took.
///
/// Recorded rather than estimated, because Phase 6 has to report "cold start to
/// first painted fleet list" with a method attached.
final class BootstrapTimings {
  const BootstrapTimings({
    required this.dependenciesMs,
    required this.sinceProcessStartMs,
  });

  final int dependenciesMs;
  final int sinceProcessStartMs;

  @override
  String toString() =>
      'deps ${dependenciesMs}ms, total ${sinceProcessStartMs}ms';
}

/// Holds the last measured startup, for the diagnostics screen and the perf
/// harness to read.
BootstrapTimings? lastBootstrapTimings;

class BootstrapGate extends StatefulWidget {
  const BootstrapGate({
    required this.processStart,
    required this.child,
    super.key,
  });

  final DateTime processStart;

  /// Built only once the database is open.
  final Widget child;

  @override
  State<BootstrapGate> createState() => _BootstrapGateState();
}

class _BootstrapGateState extends State<BootstrapGate> {
  late Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _open();
  }

  Future<void> _open() async {
    final watch = Stopwatch()..start();
    await configureDependencies();
    watch.stop();

    lastBootstrapTimings = BootstrapTimings(
      dependenciesMs: watch.elapsedMilliseconds,
      sinceProcessStartMs: DateTime.now()
          .difference(widget.processStart)
          .inMilliseconds,
    );
    debugPrint('[bootstrap] $lastBootstrapTimings');
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) => switch (snapshot.connectionState) {
      ConnectionState.done when snapshot.hasError => _BootstrapFailed(
        error: snapshot.error!,
        onRetry: () => setState(() => _ready = _open()),
      ),
      ConnectionState.done => widget.child,
      _ => const _Opening(),
    },
  );
}

class _Opening extends StatelessWidget {
  const _Opening();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 16),
          Text(
            'Opening the local database…',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    ),
  );
}

class _BootstrapFailed extends StatelessWidget {
  const _BootstrapFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.storage_outlined,
              size: 44,
              color: Color(0xFFB3261E),
            ),
            const SizedBox(height: 14),
            const Text(
              'The local database would not open',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            // The whole app is local-first, so this is not a degraded mode —
            // there is nothing to show without it. Say so plainly instead of
            // presenting an empty fleet, which would read as "no vehicles".
            const Text(
              'This app reads everything from on-device storage, so there is '
              'nothing to show until it opens.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 12),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    ),
  );
}
