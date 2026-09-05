/// Great-circle distance, checked against known values.
library;

import 'package:fleet_console/domain/rules/haversine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('haversineMetres', () {
    test('is zero for identical points', () {
      expect(
        haversineMetres(lat1: 12.9716, lon1: 77.5946, lat2: 12.9716, lon2: 77.5946),
        0,
      );
    });

    test('matches a known distance: Bengaluru to Chennai (~290 km)', () {
      final metres = haversineMetres(
        lat1: 12.9716,
        lon1: 77.5946,
        lat2: 13.0827,
        lon2: 80.2707,
      );
      expect(metres / 1000, closeTo(290, 5));
    });

    test('one degree of latitude is about 111 km anywhere', () {
      for (final lat in [0.0, 30.0, 60.0, 85.0]) {
        expect(
          haversineMetres(lat1: lat, lon1: 10, lat2: lat + 1, lon2: 10) / 1000,
          closeTo(111.2, 0.5),
          reason: 'at latitude $lat',
        );
      }
    });

    test('a degree of longitude shrinks towards the poles', () {
      final atEquator = haversineMetres(lat1: 0, lon1: 0, lat2: 0, lon2: 1);
      final atSixty = haversineMetres(lat1: 60, lon1: 0, lat2: 60, lon2: 1);

      // cos(60 degrees) is 0.5, so it should be about half.
      expect(atSixty / atEquator, closeTo(0.5, 0.01));
    });

    test('is symmetric', () {
      final there = haversineMetres(
        lat1: 12.97, lon1: 77.59, lat2: 19.07, lon2: 72.87,
      );
      final back = haversineMetres(
        lat1: 19.07, lon1: 72.87, lat2: 12.97, lon2: 77.59,
      );
      expect(there, closeTo(back, 0.001));
    });

    test('handles the antimeridian without going the long way round', () {
      // Two points 0.2 degrees apart, either side of 180. A naive lon2 - lon1
      // would compute 359.8 degrees and report most of the planet.
      final metres = haversineMetres(
        lat1: 0, lon1: 179.9, lat2: 0, lon2: -179.9,
      );
      expect(metres / 1000, closeTo(22.2, 0.5));
    });

    test('is stable for antipodal points', () {
      // Half the circumference. This is where an asin-based formula loses
      // precision, which is why the implementation uses atan2.
      final metres = haversineMetres(lat1: 0, lon1: 0, lat2: 0, lon2: 180);
      expect(metres / 1000, closeTo(20015, 5));
    });

    test('resolves geofence-scale distances precisely', () {
      // ~100 m north. The reducer decides fence membership at this scale, so
      // metre-level accuracy is what actually matters here.
      final metres = haversineMetres(
        lat1: 12.9716, lon1: 77.5946, lat2: 12.972499, lon2: 77.5946,
      );
      expect(metres, closeTo(100, 1));
    });
  });

  group('impliedSpeedKmh', () {
    test('computes a plausible road speed', () {
      final kmh = impliedSpeedKmh(
        lat1: 12.9716,
        lon1: 77.5946,
        at1: DateTime.utc(2026, 3, 1, 12),
        lat2: 12.9716,
        lon2: 77.6046,
        at2: DateTime.utc(2026, 3, 1, 12, 1),
      );
      // ~1.08 km in 60 s.
      expect(kmh, closeTo(65, 3));
    });

    test('flags a teleport', () {
      // Bengaluru to Mumbai in one minute is a bad fix, not a fast truck.
      final kmh = impliedSpeedKmh(
        lat1: 12.9716,
        lon1: 77.5946,
        at1: DateTime.utc(2026, 3, 1, 12),
        lat2: 19.0760,
        lon2: 72.8777,
        at2: DateTime.utc(2026, 3, 1, 12, 1),
      );
      expect(kmh, greaterThan(200));
    });

    test('is null when two fixes share a timestamp', () {
      // Undefined rather than infinite — the caller has to decide, and a
      // silent infinity would poison every comparison downstream.
      expect(
        impliedSpeedKmh(
          lat1: 0,
          lon1: 0,
          at1: DateTime.utc(2026, 3, 1, 12),
          lat2: 1,
          lon2: 1,
          at2: DateTime.utc(2026, 3, 1, 12),
        ),
        isNull,
      );
    });

    test('is positive even when the fixes are out of order', () {
      final backwards = impliedSpeedKmh(
        lat1: 12.9716,
        lon1: 77.5946,
        at1: DateTime.utc(2026, 3, 1, 12, 1),
        lat2: 12.9716,
        lon2: 77.6046,
        at2: DateTime.utc(2026, 3, 1, 12),
      );
      expect(backwards, isNotNull);
      expect(backwards, greaterThan(0));
    });
  });
}
