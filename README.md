# Fleet Console

A **local-first** Flutter console for a 500-truck electric fleet. Telemetry lands in an
embedded **DuckDB** database on the device; the UI reads from DuckDB. Kill the app, relaunch,
and everything it knew comes back off disk.

Flutter 3.44.1 · Dart 3.12.1 · BLoC · Clean Architecture · DuckDB 1.2.2 (embedded)

> **Status: Phase 0 complete.** The architecture spike is done and the platform decisions are
> made on measured evidence — see [`docs/00-Phase0-Spike.md`](docs/00-Phase0-Spike.md). The
> feature work (A–E) is in progress; this README grows with it.

---

## Running it

Requires [FVM](https://fvm.app) (the Flutter version is pinned in `.fvmrc`) and an
**arm64** Android device or emulator.

```bash
fvm install && fvm flutter pub get
fvm flutter run -d <device>
```

```bash
fvm flutter analyze
fvm flutter test
```

### Platform support, and one thing that will bite you

| Platform | Status |
|---|---|
| **Android arm64** | ✅ Supported. The build and measurement target. |
| macOS | ✅ Works. Used as the fast dev loop. |
| Android x86_64 | ❌ `dart_duckdb` ships no x86_64 `.so`. An Intel-host emulator cannot run this. |
| iOS simulator | ❌ Builds, then dies at runtime — see below. |
| iOS device | ⚠️ Untested. Probably works; no claim made. |

**The dependency does not work as the brief specifies.** The brief says
`dart_duckdb, currently ^1.2.0`. That caret resolves to **1.4.4**, which cannot build for
Android or iOS: versions 1.4.1–1.4.4 download their native library from GitHub release tags
that return 404. So the constraint here is pinned **exactly**:

```yaml
dart_duckdb: 1.2.2   # NOT ^1.2.0 — the caret is what breaks it
```

The reasoning is written next to the constraint in `pubspec.yaml` so it does not get
"tidied" into a range later. Details and first-hand evidence:
[`docs/00-Phase0-Spike.md`](docs/00-Phase0-Spike.md) §1.

**iOS simulator** fails because `dart_duckdb` ships a plain `.framework` rather than an
`.xcframework`, so it carries a device-only arm64 slice. CocoaPods omits it from a simulator
build and nothing fails until the first DuckDB call. Log:
[`docs/spike/ios-simulator-failure.log`](docs/spike/ios-simulator-failure.log).

### The measurement device

Perf numbers are quoted against a named, reproducible emulator:

```bash
avdmanager create avd -n fleet_pixel5_api34_arm64 \
  -k "system-images;android-34;default;arm64-v8a" -d pixel_5
```

Android 14 (API 34), arm64-v8a, 2.5 GB RAM, on an Apple Silicon host.

---

## What's actually interesting here

Storing telemetry is not the problem. These are:

**New information can arrive about the past.** Packets come late, out of order and
duplicated; a truck parks in a basement for three hours and then dumps a backlog. So
`geofence_visits` and `trips` are not incrementally patched — they are a **pure function of
the ordered event log**, replayed over a bounded window when a late packet lands. Idempotency
is structural rather than defensive: "duplicate packets create nothing twice, late packets
revise boundaries without producing duplicate trips" is not special-cased anywhere.
→ [`docs/01`](docs/01-Solution-Planning.md#5-the-core-design-decision--derived-tables-are-a-pure-function-of-the-log)

**Event time is not arrival time.** A backlog arriving now, carrying readings from three
hours ago, does not make a vehicle fresh. Every row stores both, and which one is correct
depends on the question — freshness uses one, ordering the other.

**Retention and late-packet correction are the same knob.** An append-only log grows forever,
so raw fixes are dropped after 30 days — which means raw retention *is* the replay horizon.
A packet older than that is rejected and counted, never silently applied.

**A measured number changed the design.** The naive "latest reading per vehicle" query over
2M rows runs in **39 ms on macOS and 675 ms on the target emulator** — 17× slower, and
unusable for a list that has to feel live. macOS alone would have hidden the problem
completely. That measurement is why a materialised projection exists, and both numbers get
reported.

---

## Documentation

| | |
|---|---|
| [`docs/00-Phase0-Spike.md`](docs/00-Phase0-Spike.md) | Does DuckDB actually work on device? Measured answers, and what they changed |
| [`docs/01-Solution-Planning.md`](docs/01-Solution-Planning.md) | Scope, the ambiguities and how each is resolved, architecture |

Further docs (architecture decisions, assumptions, performance, AI logs) land with the phases
that produce them.
