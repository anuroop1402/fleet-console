/// What an ingest run actually did.
library;

import 'package:equatable/equatable.dart';

import '../duckdb/schema.dart';

final class IngestReport extends Equatable {
  const IngestReport({
    required this.signalRowsWritten,
    required this.locationRowsWritten,
    required this.rejected,
  });

  static const empty = IngestReport(
    signalRowsWritten: 0,
    locationRowsWritten: 0,
    rejected: {},
  );

  final int signalRowsWritten;
  final int locationRowsWritten;

  /// Counted, never silently dropped. Also written to `rejected_packets`.
  final Map<RejectionReason, int> rejected;

  int get rejectedTotal =>
      rejected.values.fold(0, (sum, count) => sum + count);

  @override
  List<Object?> get props => [
    signalRowsWritten,
    locationRowsWritten,
    rejected,
  ];

  @override
  String toString() =>
      'IngestReport(signals: $signalRowsWritten, fixes: $locationRowsWritten, '
      'rejected: $rejected)';
}
