# 01 — Solution Planning

> Written at the end of Phase 0, **before** the real implementation began. Deliberately
> not revised afterwards — later phases record what actually changed in
> `03-Assumptions-and-Tradeoffs.md`, so the gap between plan and outcome stays visible.

**Date:** 2026-09-05
**Platform:** Flutter 3.44.1 (Dart 3.12.1), Android arm64 · BLoC · Clean Architecture

---

## 1. Problem understanding

A fleet operator with 500 electric trucks needs one screen answering three questions:
*where are my vehicles, are they okay, what needs attention now.*

The brief tells you where the difficulty is, and it is not the feature list:

> "The difficulty is not volume of features — it is that the data model has genuinely
> ambiguous cases, and we want to see how you resolve them."

Telemetry arrives late, out of order, duplicated, or not at all. Vehicles park in basements
for hours and then dump a backlog. So almost every apparently-simple question has a hidden
second question underneath it:

- "Is this vehicle offline?" → *offline by whose clock — when it emitted, or when we heard?*
- "What is its SOC?" → *the newest value we received, or the newest value it measured?*
- "Did it leave the depot?" → *did it, or did the GPS wobble 8 m across the fence line?*
- "Is that a new trip?" → *or the same trip, re-derived because a late packet arrived?*

So the deliverable is **a documented set of resolutions to ambiguity, with an app around
it** — not a feature checklist. Every resolution has to be defensible out loud.

## 2. Requirements

**Explicit (from the brief)**
- Local-first over embedded DuckDB. The UI reads from DuckDB, not from an in-memory list
  DuckDB happens to shadow. Kill the app, relaunch, everything comes back off disk.
- A — fleet home: list, status chip (first match wins), filter chips with counts in SQL
- B — vehicle detail: per-signal readings register with per-signal age and verdict pills,
  plus SOC history over the retained window
- C — alerts with escalation, a dismissal reason sheet, 5 s undo, independent resolution
- D — persisted circular geofences with a *documented deterministic strategy* for
  duplicates, late packets, jitter, inaccuracy, overlaps, gaps and edits
- E — automatic trips from confirmed transitions; idempotent and event-time aware
- Scale exercise: 500 vehicles, ≥2M signal rows, measured on a named device
- Retention policy, stated
- Comprehensive tests
- Private repo with real commit history, README, uncurated AI logs

**Inferred (my calls, not stated)**
- Every derived fact must be **rebuildable from the log**. If a projection and the log
  disagree, the log wins. This is what makes late-packet correction tractable.
- Being explicit about *not knowing* beats inventing a plausible value. `STALE` and
  `UNKNOWN` are first-class outcomes, not error states.
- The reducer logic must be testable **without a database**, or the ambiguous cases will
  never get the exhaustive coverage they need.

## 3. Questions I would have asked a PM — and what I assumed instead

| Question | Assumption committed to | Why |
|---|---|---|
| "Last ping older than 10 min" — by event time or arrival time? | **Event time vs wall-clock now.** A backlog dumped at 14:00 carrying 11:00 readings does *not* make the vehicle fresh. | Arrival time measures our network, not the truck. An operator asking "is it okay" is asking about the truck. |
| Two packets, same `event_ts`, different values. Which wins? | Higher `ingested_ts`; then `packet_id` lexicographically. | Determinism matters more than being clever. A later arrival is most plausibly a correction, and the final tiebreak guarantees replay reproduces exactly. |
| A vehicle is `MOVING` but its SOC is 3 hours old. Is it offline? | **No.** Status uses *vehicle-level* freshness (`MAX(event_ts)` across signals); the SOC pill independently reads `STALE`. | The brief separates "vehicle-level last ping" from each signal's "own age" deliberately. A truck reporting speed but not SOC is online with a missing signal. |
| SOC 18% dismissed, then drops to 8%. Does the alert come back? | **Yes, at critical.** | Escalation is new information. Silencing a warning is not consent to silence a critical. |
| SOC 8% dismissed, then recovers to 15%. | Severity de-escalates to warning; **stays dismissed**. | Severity describes the current condition. The human said "I am on it" about a battery problem that still exists. |
| An open alert's SOC goes stale. Resolve it? | **No — keep it open, flagged stale**, showing the last known value and its age. | Resolving asserts the condition cleared. We cannot see it. Silence about a possibly-burning truck is the worse error. |
| GPS says the truck crossed the fence by 4 m. Trip? | **No.** Dual-radius hysteresis plus a 2-fix / 60-second confirmation. | Otherwise a truck parked on a boundary generates infinite trips. "Confirmed" in feature E is exactly this debounce. |
| Point is inside two overlapping geofences. Which is "current"? | **Smallest radius wins**, then lowest id. | Single-valued by construction, and the more specific answer is the more useful one — a loading bay inside a depot. |
| Someone resizes a geofence. Does last month's trip history change? | **No.** Geofences are versioned (SCD-2); history is evaluated against the version in effect at the fix's event time. | Trip history that silently rewrites itself is a bug. The brief's "retain deactivated geofences for trip history" implies history must stay interpretable. |
| Units, map provider? | Metric; no map tiles — geofences render on a plain coordinate canvas. | An API key and tile plumbing prove nothing about the data model being assessed. |

## 4. Scope

**In**
- ✅ Features A–E in full
- ✅ Scale exercise with measured numbers on a named device
- ✅ Retention + compaction policy, implemented not just described
- ✅ Pure-function test suite over the ambiguous cases; DuckDB integration tests; BLoC tests
- ✅ Uncurated AI conversation logs

**Out — and why**
| Not building | Reason |
|---|---|
| Real map tiles (Google/Mapbox) | API key + tile plumbing; zero signal about the data model. A coordinate canvas shows geofence geometry fine. |
| Live network ingest (MQTT/HTTP) | A simulated packet feed reproduces late/duplicate/out-of-order arrival *more* controllably than a real broker, which is the property under test. |
| Auth, theming, localisation, onboarding | Presentation surface area. |
| iOS | Dropped in Phase 0 for a documented third-party packaging defect — see `00-Phase0-Spike.md` §2. |

Cutting *presentation* rather than features D/E is deliberate: D and E are where the brief
says the difficulty lives. Trading them for polish would be trading away the thing being
graded.

## 5. The core design decision — derived tables are a pure function of the log

Everything hard in this brief reduces to one problem: **new information can arrive about
the past.** A late packet does not just append; it can change what already happened.

Two ways to handle that:

1. **Incremental patching** — when a late fix arrives, work out which trip it affects and
   surgically amend it. Fast, and a bug farm: every combination of late/duplicate/gap needs
   its own repair path.
2. **Deterministic replay** — treat `geofence_visits` and `trips` as a *pure function* of
   (ordered fix log × geofence versions). A late fix invalidates derived rows from the last
   stable checkpoint and replays forward.

I am taking (2). The cost is recomputation over a bounded window. What it buys:

- Idempotency is **structural**, not defensive. The brief's "duplicate packets create
  nothing twice, late packets may revise boundaries without producing duplicate trips" is
  not special-cased anywhere — it falls out of the reducer being pure and the ordering
  being total.
- The reducer takes exhaustive unit tests with hand-built fixtures and **no database**.
- Correctness is auditable: replay from scratch must reproduce the same rows.

The bound matters and is not arbitrary: **raw retention *is* the replay horizon.** A fix
older than the retention window cannot be replayed, so it is rejected into
`rejected_packets` and counted, never silently applied.

## 6. Architecture

```
presentation (BLoC + widgets)  →  domain (entities, rules, reducers, use cases, interfaces)
                                     ↑
                                  data (DuckDB, ingest, repo impls)
```

- **`domain/` imports `dart:core` and `equatable` only.** No Flutter, no `dart_duckdb`, no
  I/O. Enforced by an architecture test that scans imports, not by good intentions.
- **Reducers are pure Dart, not SQL.** Hysteresis, dwell confirmation and gap handling in
  window functions would be unreadable and effectively untestable. They run on *ingest*, not
  on read, so read latency is unaffected. This also makes the missing Android `spatial`
  extension a non-issue: haversine becomes a tested Dart function instead of a SQL
  dependency.
- **`latest_readings` is a materialised projection, not a cache.** The fleet list cannot
  scan 2M rows per frame — measured at **675 ms** on the target emulator in Phase 0. A
  ~3 000-row projection, upserted under an event-time guard, makes it O(vehicles). It lives
  *in DuckDB* and is rebuildable from the log by one statement, so §2 is satisfied rather
  than dodged.
- **A small connection pool in the composition root.** Each `Connection` spawns its own
  isolate; connection-per-query would be pathological.

## 7. Project rules fixed by Phase 0 evidence

1. **Every timestamp is bound `.toUtc()` and treated as UTC end to end.** Measured: a local
   `DateTime` from IST stores 5h30m early.
2. **No function-valued column defaults** (`DEFAULT CURRENT_TIMESTAMP`) — reported to crash
   WAL replay on Android. `ingested_ts` comes from an injected `Clock`, which tests need
   anyway.
3. **Never `fetchAll()` the raw log.** Aggregate in SQL; stream when a scan is unavoidable.
4. **Isolate entry points are top-level functions** taking only what they need — an inline
   closure in a `State` method captures `this` and fails to send.
5. **`dart_duckdb` stays pinned exactly.** See `00-Phase0-Spike.md` §1.

## 8. Phases

| # | Phase | Done when |
|---|---|---|
| 0 | Spike + foundations | ✅ Persistence proven on device; platform decisions made on evidence |
| 1 | Schema + ingest | Migrations, event-time dedupe, `latest_readings` upsert, `rejected_packets` |
| 2 | Domain rules | Entities, status, staleness/verdict, haversine, alert escalation. Pure tests + architecture test |
| 3 | Features A + B | Fleet list (SQL status + counts + empty state); vehicle detail register + SOC history |
| 4 | Feature C | Alerts, escalation, reason sheet, 5 s undo, independent resolution |
| 5 | Features D + E | Geofence CRUD + versioning, the reducer, trips, replay. Largest phase |
| 6 | Scale + retention | Backfill, measured numbers, compaction, `05-Performance.md` |
| 7 | Deliverables | README, `02`–`04`, screenshots, AI log export |

## 9. Definition of done

1. Force-stop and relaunch on the target device: fleet list, alerts, geofences and trips all
   return, read from disk.
2. `flutter analyze` clean; `flutter test` exit code 0.
3. Every ambiguity in §3 has a named test asserting the documented resolution.
4. Replaying the full log from scratch reproduces the derived tables byte-for-byte.
5. Scale numbers measured on the named device, with method and a diagnosis for anything slow.
6. A reviewer can clone, run, and reach the 30-second feature tour from the README alone.
