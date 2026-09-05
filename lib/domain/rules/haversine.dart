/// Great-circle distance between two coordinates.
///
/// Written by hand rather than delegated to PostGIS-style SQL, because DuckDB
/// publishes no `spatial` extension for `linux_arm64_android` — confirmed by
/// inspecting the shipped `.so` in Phase 0. That turns out to cost nothing: the
/// geofence reducer is pure Dart anyway, so the distance function lives beside
/// it and takes direct unit tests instead of being a SQL dependency that only
/// runs on a device.
library;

import 'dart:math' as math;

/// Mean Earth radius, metres (IUGG).
///
/// The haversine formula assumes a sphere. Over geofence-scale distances the
/// error against a proper ellipsoid model is well under a metre — far smaller
/// than the GPS accuracy the reducer already has to tolerate, and smaller than
/// the hysteresis buffer. Vincenty would be more precise and would change no
/// decision this app makes.
const double earthRadiusMetres = 6371008.8;

/// Distance in metres between two WGS-84 coordinates.
///
/// Correct across the antimeridian and at the poles, because the formula works
/// on the chord rather than on raw longitude differences — a naive
/// `lon2 - lon1` would report half the planet for two points either side of
/// 180°.
double haversineMetres({
  required double lat1,
  required double lon1,
  required double lat2,
  required double lon2,
}) {
  final phi1 = _radians(lat1);
  final phi2 = _radians(lat2);
  final deltaPhi = _radians(lat2 - lat1);
  final deltaLambda = _radians(lon2 - lon1);

  final sinHalfPhi = math.sin(deltaPhi / 2);
  final sinHalfLambda = math.sin(deltaLambda / 2);

  final a = sinHalfPhi * sinHalfPhi +
      math.cos(phi1) * math.cos(phi2) * sinHalfLambda * sinHalfLambda;

  // atan2 rather than asin: it stays numerically stable for antipodal points,
  // where `a` approaches 1 and asin loses precision badly.
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

  return earthRadiusMetres * c;
}

/// Implied speed in km/h between two fixes.
///
/// Used by the reducer's teleport filter: a GPS fix implying 900 km/h is a bad
/// fix, not a fast truck. Returns null when the two fixes share a timestamp,
/// since the speed is undefined rather than infinite.
double? impliedSpeedKmh({
  required double lat1,
  required double lon1,
  required DateTime at1,
  required double lat2,
  required double lon2,
  required DateTime at2,
}) {
  final seconds = at2.difference(at1).inMicroseconds / 1e6;
  if (seconds == 0) return null;

  final metres = haversineMetres(
    lat1: lat1,
    lon1: lon1,
    lat2: lat2,
    lon2: lon2,
  );
  return (metres / seconds.abs()) * 3.6;
}

double _radians(double degrees) => degrees * math.pi / 180.0;
