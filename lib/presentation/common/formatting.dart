/// Display helpers shared by the fleet screens.
///
/// Formatting only. No thresholds, no staleness decisions — those are domain
/// rules and arrive here already decided, as a `Verdict` or a `VehicleStatus`.
library;

import 'package:flutter/material.dart';

import '../../domain/entities/signal_kind.dart';
import '../../domain/entities/vehicle_status.dart';
import '../../domain/entities/verdict.dart';

/// A compact age, e.g. "4s", "12m", "3h", "2d".
///
/// Ages are the whole point of this screen, so they stay short enough to sit in
/// a table cell without wrapping.
String formatAge(Duration age) {
  if (age.isNegative) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// The em dash used for a signal that has never reported.
///
/// Deliberately not "0", "N/A" or an empty cell: the brief asks for "—", and it
/// has to read as *absence of data* rather than as a value.
const String noValue = '—';

String formatSignalValue(SignalKind kind, double? value) {
  if (value == null) return noValue;
  return switch (kind) {
    SignalKind.soc => '${value.round()}%',
    SignalKind.speed => '${value.round()} km/h',
    SignalKind.batteryTemp => '${value.toStringAsFixed(1)} °C',
    SignalKind.odometer => '${_thousands(value.round())} km',
    SignalKind.rangeKm => '${value.round()} km',
    SignalKind.ignition => value != 0 ? 'On' : 'Off',
  };
}

String signalLabel(SignalKind kind) => switch (kind) {
  SignalKind.soc => 'State of charge',
  SignalKind.speed => 'Speed',
  SignalKind.batteryTemp => 'Battery temperature',
  SignalKind.odometer => 'Odometer',
  SignalKind.rangeKm => 'Range',
  SignalKind.ignition => 'Ignition',
};

String statusLabel(VehicleStatus status) => switch (status) {
  VehicleStatus.offline => 'Offline',
  VehicleStatus.moving => 'Moving',
  VehicleStatus.idle => 'Idle',
  VehicleStatus.stopped => 'Stopped',
  VehicleStatus.unknown => 'Unknown',
};

Color statusColour(VehicleStatus status, ColorScheme scheme) =>
    switch (status) {
      VehicleStatus.moving => const Color(0xFF1B7F4B),
      VehicleStatus.idle => const Color(0xFFB26A00),
      VehicleStatus.stopped => const Color(0xFF4A5568),
      VehicleStatus.offline => const Color(0xFF8B1A1A),
      // Grey, like STALE: the app is saying it does not know, and that should
      // not look like a healthy state.
      VehicleStatus.unknown => const Color(0xFF6B7280),
    };

String verdictLabel(Verdict verdict) => switch (verdict) {
  Verdict.normal => 'NORMAL',
  Verdict.alert => 'ALERT',
  Verdict.stale => 'STALE',
  Verdict.neverReported => '',
};

Color verdictColour(Verdict verdict) => switch (verdict) {
  Verdict.normal => const Color(0xFF1B7F4B),
  Verdict.alert => const Color(0xFFB3261E),
  // Grey is load-bearing. STALE makes no normal/alert claim, so it must not
  // borrow the colour of either.
  Verdict.stale => const Color(0xFF6B7280),
  Verdict.neverReported => const Color(0xFF9CA3AF),
};

String _thousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value.isNegative ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
