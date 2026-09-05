/// Turns a noisy location log into confirmed geofence transitions.
///
/// A **pure function** of (fixes × geofence versions). No clock, no I/O, no
/// database. That is what makes the seven failure modes the brief names
/// testable with hand-built fixtures instead of database scenarios, and it is
/// what makes replay idempotent: the same log always reduces to the same
/// answer, so a late packet can simply be replayed rather than surgically
/// patched into existing rows.
///
/// The strategy, in processing order:
///
/// 1. **Total order** — `event_ts`, then `ingested_ts`, then `packet_id`.
/// 2. **Duplicates** — identical `(vehicle, event_ts)` collapse to one.
/// 3. **Inaccurate readings** — dropped when they cannot decide any fence.
/// 4. **Teleports** — an implied speed above the plausible limit is a bad fix.
/// 5. **Jitter** — dual-radius hysteresis; in the band, state is sticky.
/// 6. **Confirmation** — N consecutive agreeing fixes *and* a dwell window.
/// 7. **Gaps** — a long silence breaks the dwell chain and flags what follows.
/// 8. **Edits** — each fix is evaluated against the version live at its own
///    event time.
///
/// Overlaps are resolved by [currentGeofenceFor], not here: a vehicle can be
/// inside two fences at once and both visits are real; only the *displayed*
/// "current geofence" has to be single-valued.
library;

import '../../core/constants.dart';
import '../entities/geofence.dart';
import '../rules/haversine.dart';

/// Where a fix places a vehicle relative to one fence.
enum _Membership {
  inside,
  outside,

  /// In the hysteresis band, or too inaccurate for this particular fence.
  /// Carries no opinion — the previous state stands.
  ambiguous,
}

/// A fix the reducer refused, and why. Nothing is dropped silently.
final class RejectedFix {
  const RejectedFix(this.fix, this.reason, this.detail);

  final LocationFix fix;
  final FixRejection reason;
  final String detail;

  @override
  String toString() => '${fix.packetId}: ${reason.wireName} ($detail)';
}

/// Everything one reduction produced.
final class GeofenceReduction {
  const GeofenceReduction({
    required this.transitions,
    required this.visits,
    required this.rejected,
    required this.acceptedFixCount,
  });

  static const empty = GeofenceReduction(
    transitions: [],
    visits: [],
    rejected: [],
    acceptedFixCount: 0,
  );

  final List<ConfirmedTransition> transitions;
  final List<GeofenceVisit> visits;
  final List<RejectedFix> rejected;
  final int acceptedFixCount;
}

/// Per-fence state carried across fixes.
final class _FenceState {
  _FenceState();

  /// The last state we were willing to commit to.
  ///
  /// Null until the first unambiguous fix. Starting at `false` would be an
  /// assumption that every vehicle begins outside every fence, which is wrong
  /// for the common case of a log that starts in the depot — the first fixes
  /// inside would then look like an arrival, and the real departure that
  /// followed would look like nothing at all, because it would "agree" with
  /// the assumed state.
  bool? confirmedInside;

  /// The state the current run of fixes is arguing for, if it disagrees with
  /// [confirmedInside].
  bool? candidateInside;

  /// Event time of the first fix in that run — the actual crossing.
  DateTime? candidateSince;

  /// How many consecutive fixes have agreed.
  int candidateRun = 0;

  /// The run began immediately after a reporting gap, so its crossing time is
  /// inferred rather than observed.
  bool candidateAfterGap = false;

  /// Open visit, when confirmed inside.
  DateTime? visitEnteredAt;
  String? visitVersionId;
  bool visitInferred = false;

  void clearCandidate() {
    candidateInside = null;
    candidateSince = null;
    candidateRun = 0;
    candidateAfterGap = false;
  }
}

/// Reduces one vehicle's fixes against a set of geofence versions.
///
/// [fixes] may arrive in any order and may contain duplicates; ordering and
/// de-duplication happen here so callers cannot get it wrong.
GeofenceReduction reduceGeofences({
  required String vehicleId,
  required List<LocationFix> fixes,
  required List<GeofenceVersion> versions,
}) {
  if (fixes.isEmpty) return GeofenceReduction.empty;

  final ordered = [...fixes]..sort(LocationFix.compare);

  final transitions = <ConfirmedTransition>[];
  final visits = <GeofenceVisit>[];
  final rejected = <RejectedFix>[];
  final states = <String, _FenceState>{};

  LocationFix? previousAccepted;
  DateTime? previousEventTs;
  var accepted = 0;

  for (final fix in ordered) {
    // (2) Duplicates. Same vehicle, same instant: the tie-break already put
    // the winner first, so anything after it at the same event time is a
    // repeat. Note this is by event time alone — two different packets
    // claiming the same instant are contradictory, and taking the first by
    // total order is the deterministic choice.
    if (previousEventTs != null && !fix.eventTs.isAfter(previousEventTs)) {
      rejected.add(
        RejectedFix(fix, FixRejection.duplicate, 'same event time as a kept fix'),
      );
      continue;
    }

    // (3) Inaccurate readings.
    if (fix.accuracyMetres > GeofencePolicy.maxUsableAccuracyMetres) {
      rejected.add(
        RejectedFix(
          fix,
          FixRejection.tooInaccurate,
          '${fix.accuracyMetres.round()} m exceeds '
              '${GeofencePolicy.maxUsableAccuracyMetres.round()} m',
        ),
      );
      continue;
    }

    // (4) Teleports.
    if (previousAccepted != null) {
      final speed = impliedSpeedKmh(
        lat1: previousAccepted.latitude,
        lon1: previousAccepted.longitude,
        at1: previousAccepted.eventTs,
        lat2: fix.latitude,
        lon2: fix.longitude,
        at2: fix.eventTs,
      );
      if (speed != null && speed > GeofencePolicy.maxPlausibleSpeedKmh) {
        rejected.add(
          RejectedFix(
            fix,
            FixRejection.teleport,
            '${speed.round()} km/h from the previous fix',
          ),
        );
        continue;
      }
    }

    // (7) Gaps. A silence longer than the limit means we cannot claim the
    // vehicle stayed where it was, so every dwell chain restarts.
    final afterGap =
        previousAccepted != null &&
        fix.eventTs.difference(previousAccepted.eventTs) >
            GeofencePolicy.maxReportingGap;
    if (afterGap) {
      for (final state in states.values) {
        state.clearCandidate();
      }
    }

    accepted++;
    previousAccepted = fix;
    previousEventTs = fix.eventTs;

    // (8) Edits: only versions live at this fix's own event time may speak.
    for (final version in versions) {
      if (!version.isLiveAt(fix.eventTs)) continue;

      final state = states.putIfAbsent(
        version.geofenceId,
        () => _FenceState(),
      );

      final membership = _membershipOf(fix, version);
      if (membership == _Membership.ambiguous) {
        // (5) Sticky. The band carries no opinion, and a fix that says nothing
        // must not break a run that is otherwise building.
        continue;
      }

      final isInside = membership == _Membership.inside;

      if (state.confirmedInside == null) {
        // First sighting for this fence. It establishes where the vehicle is,
        // but it is not a crossing: we never saw it on the other side, so
        // there is nothing to report. Confirmation debounces crossings, not
        // the act of finding out where something already was.
        state.confirmedInside = isInside;
        if (isInside) {
          state
            ..visitEnteredAt = fix.eventTs
            ..visitVersionId = version.versionId
            ..visitInferred = false;
        }
        state.clearCandidate();
        continue;
      }

      if (isInside == state.confirmedInside) {
        // Agrees with what we already believe; any counter-run collapses.
        state.clearCandidate();
        continue;
      }

      if (state.candidateInside != isInside) {
        // A new disagreement starts a fresh run, timed from this fix.
        state
          ..candidateInside = isInside
          ..candidateSince = fix.eventTs
          ..candidateRun = 1
          ..candidateAfterGap = afterGap;
      } else {
        state.candidateRun++;
      }

      // (6) Confirmation: enough agreeing fixes AND enough elapsed time.
      final dwell = fix.eventTs.difference(state.candidateSince!);
      final confirmed =
          state.candidateRun >= GeofencePolicy.confirmationFixes &&
          dwell >= GeofencePolicy.confirmationDwell;
      if (!confirmed) continue;

      final crossedAt = state.candidateSince!;
      final inferred = state.candidateAfterGap;

      transitions.add(
        ConfirmedTransition(
          vehicleId: vehicleId,
          geofenceId: version.geofenceId,
          versionId: version.versionId,
          kind: isInside ? TransitionKind.entry : TransitionKind.exit,
          crossedAt: crossedAt,
          confirmedAt: fix.eventTs,
          inferredDuringGap: inferred,
        ),
      );

      if (isInside) {
        state
          ..visitEnteredAt = crossedAt
          ..visitVersionId = version.versionId
          ..visitInferred = inferred;
      } else if (state.visitEnteredAt != null) {
        visits.add(
          GeofenceVisit(
            vehicleId: vehicleId,
            geofenceId: version.geofenceId,
            versionId: state.visitVersionId ?? version.versionId,
            enteredAt: state.visitEnteredAt!,
            exitedAt: crossedAt,
            inferredDuringGap: state.visitInferred || inferred,
          ),
        );
        state
          ..visitEnteredAt = null
          ..visitVersionId = null
          ..visitInferred = false;
      }

      state
        ..confirmedInside = isInside
        ..clearCandidate();
    }
  }

  // Visits still open at the end of the log are real — the vehicle is still
  // there. Emitted with a null exit rather than dropped.
  for (final entry in states.entries) {
    final state = entry.value;
    if (state.visitEnteredAt == null) continue;
    visits.add(
      GeofenceVisit(
        vehicleId: vehicleId,
        geofenceId: entry.key,
        versionId: state.visitVersionId!,
        enteredAt: state.visitEnteredAt!,
        inferredDuringGap: state.visitInferred,
      ),
    );
  }

  transitions.sort((a, b) {
    final byTime = a.crossedAt.compareTo(b.crossedAt);
    if (byTime != 0) return byTime;
    // Deterministic even when two fences are crossed at the same instant.
    return a.geofenceId.compareTo(b.geofenceId);
  });

  return GeofenceReduction(
    transitions: transitions,
    visits: visits,
    rejected: rejected,
    acceptedFixCount: accepted,
  );
}

/// Dual-radius hysteresis.
///
/// The buffer widens with the fix's own accuracy, so a sloppy fix has to be
/// further past the line before it counts. When accuracy is so poor that the
/// inside band vanishes (`buffer >= radius`), the fence is simply undecidable
/// for this fix.
_Membership _membershipOf(LocationFix fix, GeofenceVersion version) {
  final distance = haversineMetres(
    lat1: fix.latitude,
    lon1: fix.longitude,
    lat2: version.latitude,
    lon2: version.longitude,
  );

  final buffer = fix.accuracyMetres > GeofencePolicy.minHysteresisMetres
      ? fix.accuracyMetres
      : GeofencePolicy.minHysteresisMetres;

  if (buffer >= version.radiusMetres) {
    // The bands overlap: there is no position that would count as inside.
    return distance > version.radiusMetres + buffer
        ? _Membership.outside
        : _Membership.ambiguous;
  }

  if (distance < version.radiusMetres - buffer) return _Membership.inside;
  if (distance > version.radiusMetres + buffer) return _Membership.outside;
  return _Membership.ambiguous;
}

/// (6) Overlaps: which single fence to show as a vehicle's "current" one.
///
/// A vehicle really can be inside a loading bay inside a depot, and both visits
/// are true. Only the display has to pick one, so it picks the **most
/// specific** — smallest radius — then the lowest id for determinism. A bay is
/// a more useful answer than the depot that contains it.
GeofenceVersion? currentGeofenceFor(
  Iterable<GeofenceVersion> containing,
) {
  GeofenceVersion? best;
  for (final candidate in containing) {
    if (best == null ||
        candidate.radiusMetres < best.radiusMetres ||
        (candidate.radiusMetres == best.radiusMetres &&
            candidate.geofenceId.compareTo(best.geofenceId) < 0)) {
      best = candidate;
    }
  }
  return best;
}

/// The fence versions that contain [fix], ignoring hysteresis.
///
/// Used for the "where is it now" display, which is a snapshot question rather
/// than a transition question — debouncing a label the user is looking at right
/// now would make it lag reality for no benefit.
List<GeofenceVersion> containingFences(
  LocationFix fix,
  Iterable<GeofenceVersion> versions,
) => [
  for (final version in versions)
    if (version.isLiveAt(fix.eventTs) &&
        haversineMetres(
              lat1: fix.latitude,
              lon1: fix.longitude,
              lat2: version.latitude,
              lon2: version.longitude,
            ) <=
            version.radiusMetres)
      version,
];
