# Fleet Console

Take-home exercise: a **local-first Flutter fleet console** for 500 electric trucks over an
embedded **DuckDB** database on device. One screen answers *where are my vehicles, are they
okay, what needs attention now.*

Assessed on how genuinely ambiguous data-model cases are resolved, not on feature volume.
All written reasoning lives in `docs/` — start at `docs/01-Solution-Planning.md`.

---

## Current state — update this at the end of every phase

**Phase 2 complete.** Domain rules are in — status chip, staleness/verdict, haversine and
the alert state machine — plus an architecture test that enforces the layer boundary.
**98 tests** green, `flutter analyze` clean.

Next: Phase 3 — features A and B (fleet list with SQL status + filter counts; vehicle detail
readings register and SOC history).

| Phase | | |
|---|---|---|
| 0 | Spike, platform decisions, `docs/00`, `docs/01` | ✅ |
| 1 | Schema + ingest: migrations, dedupe, `latest_readings`, `rejected_packets` | ✅ |
| 2 | Domain: entities, status/staleness/verdict, haversine, alert escalation | ✅ |
| 3 | Features A + B: fleet list, vehicle detail | ⬜ |
| 4 | Feature C: alerts, dismissal, undo | ⬜ |
| 5 | Features D + E: geofences, reducer, trips, replay | ⬜ |
| 6 | Scale + retention, `docs/05-Performance.md` | ⬜ |
| 7 | README, `docs/02`–`04`, screenshots, AI logs | ⬜ |

## Hard-won facts — verified on device in Phase 0, do not re-litigate

- **`dart_duckdb` is pinned to `1.2.2` exactly. Never widen it to a caret range.**
  `^1.2.0` resolves to 1.4.4, which cannot build for Android or iOS — its Gradle script and
  podspec download from GitHub release tags that 404. The reason is written next to the
  constraint in `pubspec.yaml`.
- **Every timestamp is bound `.toUtc()` and treated as UTC end to end.** DuckDB `TIMESTAMP`
  is timezone-naive and the binding stores `microsecondsSinceEpoch`. Measured on an IST
  device: a local `DateTime(2026,1,1,12:00)` comes back as `2026-01-01 06:30:00Z`. Reads are
  always `isUtc: true`. Getting this wrong silently corrupts event-time ordering, staleness
  and every `date_trunc` bucket — i.e. all of features D and E.
- **No function-valued column defaults** (`DEFAULT CURRENT_TIMESTAMP`) — reported to crash
  WAL replay on Android. Timestamps come from an injected `Clock`.
- **Isolate entry points are top-level functions** taking only what they need. An inline
  closure inside a `State` method captures `this`, and `Isolate.run` then tries to send the
  whole widget tree ("object is unsendable"). This actually happened.
- **Never `fetchAll()` the raw log.** It is synchronous and materialises everything.
  Aggregate in SQL; use `fetchAllStream()` when a scan is unavoidable.
- **No `spatial` extension on Android** — DuckDB publishes no extension repo for
  `linux_arm64_android`. Haversine is a pure Dart function in `domain/rules/`.
- **Android and macOS run different DuckDB engines** (v1.2.2 vs v1.2.1) from the same
  package version. Validate SQL on Android before trusting it.
- **iOS simulator is dropped** — `dart_duckdb` ships a device-only `.framework`, so the
  build succeeds and then dies at runtime. Not our bug, but not our platform either.
- `Connection` spawns one isolate each, so **connections are expensive** — pool them.
- **Host tests work.** `dart_duckdb` is a plugin, so under `flutter test` the native library
  is not bundled. `test/support/duckdb_test_env.dart` points at the shipped dylib by reading
  `.dart_tool/package_config.json`. Do not use `Isolate.resolvePackageUri` — it throws
  `Unsupported operation` in the test environment. This is why DuckDB integration tests run
  in the fast loop instead of only on a device.
- **`ON CONFLICT (...) DO UPDATE ... WHERE` works** on the bundled DuckDB 1.2.1, and so do
  `QUALIFY`, `LAG` and window functions. Verified, not assumed.
- **`ON CONFLICT` cannot update the same target row twice in one statement.** Collapse a
  batch to one row per key with `ROW_NUMBER()` before upserting, or a batch carrying two
  readings for one signal will fail.
- **`prefer_initializing_formals` is disabled project-wide** — it suggests
  `required this._field`, which is not valid Dart for a named parameter.

## Architecture — non-negotiable

```
presentation (BLoC) → domain (entities, rules, reducers, use cases, interfaces) ← data (DuckDB)
```

- **`domain/` imports `dart:core`, `dart:math` and `equatable` only.** No Flutter, no
  `dart_duckdb`, no I/O. `test/architecture_test.dart` reads the real import statements off
  disk and also fails on a `DateTime.now()` inside `rules/` or `reducers/`. It has been
  verified to actually fail by deliberately breaking it — keep it that way.
- **BLoCs call use cases. Never repositories.**
- Repository *interfaces* live in `domain/repositories/`; implementations in
  `data/repositories/`.
- Composition root is `lib/app/di.dart`. Nothing else constructs concrete dependencies.
- **Reducers (`domain/reducers/`) are pure functions** over an ordered list of fixes plus
  geofence versions. No I/O, no clock reads, no database. They run on ingest, not on read.
- **Derived tables are a pure function of the log.** `geofence_visits` and `trips` are
  rebuildable by replay; if a projection and the log disagree, the log wins.

## Domain decisions settled in Phase 2 — see docs/01 §3

- **`VehicleStatus.unknown` exists.** The brief's four status rules are not exhaustive:
  packets carry a subset of signals, so "online but nothing fresh to classify" is real.
  Falling through to `STOPPED` would assert ignition-off from an absence of evidence. It has
  no filter chip — such vehicles appear under All and nowhere else.
- **Stale readings do not classify.** Speed and ignition are consulted only while fresh, so
  the status chip agrees with the verdict pill showing the same reading as `STALE`.
- **`Verdict.neverReported` is distinct from `Verdict.stale`.** "No value" and "a value we
  refuse to judge" are different facts; only the latter draws a pill.
- **`ConditionObservation` has three cases, not two.** `Clear` and `Unobservable` must never
  collapse — a stale reading is not evidence a problem went away.
- **A dismissal holds only while severity stays at or below the severity it was dismissed
  at.** That single comparison is what makes a dismissed warning reappear on escalation to
  critical while a dismissed critical stays hidden when it recovers to warning.

## Conventions

- **Never read `DateTime.now()` inside a rule, reducer or formatter.** Inject `Clock`. A
  hidden environment read makes tests assert the developer's machine.
- Thresholds (10 min offline, 20%/10% SOC, 45 °C, 15 m hysteresis buffer, 60 s dwell,
  2-fix confirmation, 30 min gap, 200 km/h teleport) are **named constants** in
  `core/constants.dart`. No magic numbers.
- SQL lives in `data/duckdb/queries/` as named constants, not inline string literals.
- Status and filter counts are **computed in SQL**, as the brief requires.
- Tests: `flutter_test` + `bloc_test`. Pure-domain tests need no database.

## Verify before calling a phase done

```bash
export PATH="$HOME/fvm/versions/3.44.1/bin:$PATH"
flutter analyze     # must be clean, not merely free of errors
flutter test        # exit code 0 — absence of visible failures is not a pass
```

On-device check for anything touching persistence or the UI:

```bash
flutter run -d emulator-5554
adb shell am force-stop com.anuroop.fleet_console   # then relaunch: state must return
```

**Look at the app against real data before calling anything done.** In DayCast, three real
bugs were found by looking at the screen and none by the suite — every individual number was
correct and the combination lied. The equivalents here: a `MOVING` vehicle whose SOC pill
reads `STALE`; a backlog dump that must not read as fresh; a dismissed warning escalating to
critical; a late fix revising a trip boundary without duplicating the trip.

## Documentation

`docs/` is the single home for planning, decisions, assumptions and trade-offs. Do not
scatter rationale across code comments; the README stays short and links into `docs/`.

Deliverable 3 asks for **uncurated** AI logs — raw transcripts exported to `ai-logs/` by
`tool/export_ai_logs.dart`. `docs/04-AI-Usage.md` is a short curated *index* pointing into
them, not a replacement for them.

## Working style

Work proceeds in phases. Each phase ends on a green build and passing tests, then **the user
commits** — do not run `git commit`, `git push`, or create branches.
