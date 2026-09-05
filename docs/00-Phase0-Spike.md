# 00 — Phase 0 spike: does DuckDB actually work on device?

**Date:** 2026-09-05

The brief makes local-first persistence over embedded DuckDB a *hard architectural
requirement* (§2), not a preference. So before any domain model, schema or UI was written,
one question had to be answered with evidence:

> Does a file-backed DuckDB database work on the target devices, and does it survive the
> app being killed?

The rule for this phase was set in advance: **a platform that fails is dropped and
reported, not worked around.**

The spike lived in `lib/main.dart` and is deleted in Phase 1. Raw output is in
`docs/spike/`.

---

## 1. The dependency does not work as the brief specifies

The brief says `dart_duckdb, currently ^1.2.0`. Taken literally, that produces an app that
**does not compile for Android or iOS**.

`^1.2.0` means `>=1.2.0 <2.0.0`, which resolves to the latest published version, **1.4.4**.
Versions 1.4.1 through 1.4.4 download their native library from GitHub release tags that do
not exist:

| Package version | Downloads from tag | Release exists? |
|---|---|---|
| 1.2.0, 1.2.2 | `v1.2.0` | ✅ yes |
| 1.4.1 – 1.4.3 | `v1.4.1` | ❌ 404 |
| 1.4.4 | `v1.4.4` | ❌ 404 |

Upstream issues [#42], [#39] and [#38] report this; the repository has had no commits since
November 2025.

**Resolution: pin `dart_duckdb: 1.2.2` exactly** — not a caret range, because the caret is
precisely the thing that breaks it. The reasoning is recorded in `pubspec.yaml` next to the
constraint, so nobody "tidies" it into `^1.2.2` later.

Verified first-hand: the Android build log shows the download resolving against the
existing release.

```
Downloading https://github.com/TigerEyeLabs/duckdb-dart/releases/download/v1.2.0/libduckdb-android_arm64-v8a.zip
✓ Built build/app/outputs/flutter-apk/app-release.apk (111.9MB)
```

---

## 2. Results by platform

### Android — PASS, and this is the target

`fleet_pixel5_api34_arm64` · Android 14 (API 34) · **arm64-v8a** · 2.5 GB RAM ·
Apple Silicon host · timezone Asia/Kolkata

**10 checks passed, 0 failed.**

| Check | Result |
|---|---|
| Native library loads | DuckDB **v1.2.2** |
| `open()` + `connect()` | **470 ms** |
| **Persistence across force-stop** | **PROVEN** — launch counter read 1 row at startup, wrote the 2nd |
| Timestamp round-trip | local `DateTime(2026,1,1,12:00)` → `2026-01-01 06:30:00Z` |
| `core_functions` (trig/math) | all 6 probed functions present |
| `spatial` extension | unavailable, as expected |
| 2M rows via `range()` | **344 ms** (5.8M rows/sec) |
| Naive latest-per-vehicle over 2M rows | **675 ms** |
| `LAG` + `QUALIFY` | works |
| Background isolate (`TransferableDatabase`) | 50k rows in 116 ms, visible to the main connection |
| `CHECKPOINT` | 7 ms; 2M rows = **5.0 MB** on disk |

Persistence was tested the only way that actually proves anything: `adb shell am force-stop`,
then relaunch. The app appends one row per launch and reports how many it found *before*
writing. Finding 1 row on the second launch means the data genuinely came off disk.

Evidence: `docs/spike/android-checks-upper.png`, `docs/spike/android-checks-lower.png`.

### macOS — PASS (used as the fast dev loop, not for measurement)

DuckDB **v1.2.1** · release build · 144.3 MB `.app`

`open()` 123 ms · 2M rows in 176 ms · naive query **39 ms** · isolate 105 ms · checkpoint 3 ms.

Persistence proven the same way across two separate process launches.

### iOS simulator — FAIL. Dropped.

The build **succeeds**, which is misleading. The app then dies at the first DuckDB call:

```
Failed to load dynamic library 'duckdb.framework/duckdb':
  dlopen(duckdb.framework/duckdb, 0x0001): tried:
  …/Runner.app/Frameworks/duckdb.framework/duckdb (no such file)
```

`dart_duckdb` ships a plain `.framework`, not an `.xcframework`, so it carries a device
arm64 slice only. CocoaPods therefore omits it from a simulator build — and nothing fails
until runtime. Upstream [#14].

**iOS simulator is out of scope, and the reason is a third-party packaging defect, not the
architecture.** A physical iPhone would very likely work (same arm64 slice) but is untested,
so no claim is made either way. Full log: `docs/spike/ios-simulator-failure.log`.

---

## 3. What the spike changed

**The measurement device changed.** The plan named `Pixel_8_Pro_API_31`. That AVD points at
an `android-31` system image that is not installed on this machine, and the emulator refuses
to boot. Rather than download a stale API level, Phase 0 created a clean, honestly-named AVD
on the API 34 arm64 image already present:

```bash
avdmanager create avd -n fleet_pixel5_api34_arm64 \
  -k "system-images;android-34;default;arm64-v8a" -d pixel_5
```

Named in the README so the numbers are reproducible.

**The two platforms run different DuckDB engines.** Android reports **v1.2.2**, macOS
reports **v1.2.1** — Android uses TigerEyeLabs' own build, macOS pulls the stock DuckDB
universal dylib. Same package version, different engine. Nothing has depended on the
difference yet, but SQL is validated on Android before it is trusted.

**The 675 ms naive query justifies the materialised projection, with a measured number.**
On macOS the same query is 39 ms — fast enough to hide the problem entirely. On the
emulator it is **17× slower** and unusable for a list that has to feel live. Phase 6 reports
both, and the projection has a real "before" to beat. This is exactly the case the brief
describes: a measured 900 ms with a diagnosis beats an unmeasured claim of 40 ms.

**The timestamp hazard is real and confirmed on device.** Both platforms are on IST. Binding
a *local* `DateTime(2026,1,1,12:00)` stores `2026-01-01 06:30:00Z`, because the binding
writes `microsecondsSinceEpoch` into a timezone-naive DuckDB `TIMESTAMP`. Reads always come
back `isUtc: true`.

> **Project rule: every timestamp is bound `.toUtc()` and treated as UTC end to end.**

Left unchecked this would silently corrupt event-time ordering, staleness, and any
`date_trunc('day', …)` bucketing — the exact machinery features D and E are built on.

**One bug was mine, not the library's.** The first isolate check failed with
*"object is unsendable — Instance of 'WidgetsFlutterBinding'"*. An inline closure inside a
`State` method captures the enclosing context, which includes `this`, so `Isolate.run` tried
to ship the entire widget tree. Fixed by hoisting the work into a top-level function taking
the `TransferableDatabase` as its only argument. Worth recording because the backfill and
the replay coordinator both depend on this path.

**App size is a real cost.** 111.9 MB APK for arm64 alone; the `libduckdb.so` is ~66 MB
uncompressed. Reported in Phase 6 rather than hidden.

---

## 4. Verdict

The architecture the brief requires is viable. **Android is the build and measurement
target**, macOS is the fast dev loop, iOS simulator is dropped with a documented reason.

Nothing below was assumed — every row above was executed on the device it claims.
