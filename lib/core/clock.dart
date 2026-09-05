/// Time is injected, never read ambiently.
///
/// A rule or reducer that calls `DateTime.now()` internally makes its tests
/// assert the developer's machine and the moment they ran. Every component that
/// needs "now" takes a [Clock].
///
/// Everything here is UTC. DuckDB `TIMESTAMP` is timezone-naive and the
/// `dart_duckdb` binding stores `microsecondsSinceEpoch`, so a local `DateTime`
/// silently shifts by the device offset — measured at −5:30 on an IST device in
/// Phase 0. See docs/00-Phase0-Spike.md §3.
library;

abstract interface class Clock {
  /// The current instant, always in UTC.
  DateTime nowUtc();
}

/// The real clock. Used everywhere outside tests.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// A clock that stands still, and can be moved deliberately.
///
/// Staleness, offline status and alert transitions are all functions of elapsed
/// time, so tests need to control it rather than sleep.
final class FixedClock implements Clock {
  FixedClock(DateTime now) : _now = now.toUtc();

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  /// Moves the clock forward. Negative durations are rejected — time going
  /// backwards in a test is almost always a mistake in the test.
  void advance(Duration by) {
    if (by.isNegative) {
      throw ArgumentError.value(by, 'by', 'Clock cannot move backwards');
    }
    _now = _now.add(by);
  }

  void setTo(DateTime instant) => _now = instant.toUtc();
}
