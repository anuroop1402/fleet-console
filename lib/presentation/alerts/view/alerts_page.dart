/// Feature C — alerts, dismissal and undo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants.dart';
import '../../../domain/entities/alert.dart';
import '../../../domain/entities/fleet_view.dart';
import '../../common/formatting.dart';
import '../bloc/alerts_bloc.dart';

class AlertsPage extends StatelessWidget {
  const AlertsPage({this.onVehicleTap, super.key});

  final void Function(String vehicleId)? onVehicleTap;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Alerts'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () =>
              context.read<AlertsBloc>().add(const AlertsRequested()),
        ),
      ],
    ),
    body: BlocConsumer<AlertsBloc, AlertsState>(
      listenWhen: (previous, current) =>
          previous.undoable != current.undoable && current.undoable != null,
      listener: (context, state) => _showUndo(context, state.undoable!),
      builder: (context, state) => switch (state.status) {
        AlertsStatus.initial ||
        AlertsStatus.loading when state.alerts.isEmpty =>
          const Center(child: CircularProgressIndicator()),
        AlertsStatus.failed => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(state.error ?? 'Unknown error'),
          ),
        ),
        _ when state.isEmpty => const _NothingToSee(),
        _ => ListView.separated(
          itemCount: state.alerts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) => _AlertTile(
            view: state.alerts[index],
            onTap: onVehicleTap,
          ),
        ),
      },
    ),
  );

  void _showUndo(BuildContext context, Alert dismissed) {
    final bloc = context.read<AlertsBloc>();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Dismissed ${_alertTitle(dismissed.kind)}'),
          // Matches the window the use case enforces. The use case checks it
          // again on tap, so a snackbar left on screen by a sleeping device
          // cannot rewrite an old decision.
          duration: FleetThresholds.undoWindow,
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () => bloc.add(const AlertDismissalUndone()),
          ),
        ),
      );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.view, this.onTap});

  final AlertView view;
  final void Function(String vehicleId)? onTap;

  @override
  Widget build(BuildContext context) {
    final alert = view.alert;
    final critical = alert.severity == AlertSeverity.critical;
    final colour = critical
        ? const Color(0xFFB3261E)
        : const Color(0xFFB26A00);

    return ListTile(
      onTap: onTap == null ? null : () => onTap!(alert.vehicleId),
      leading: Icon(
        critical ? Icons.error : Icons.warning_amber_rounded,
        color: alert.isConditionStale ? const Color(0xFF6B7280) : colour,
      ),
      title: Text(
        _alertTitle(alert.kind),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          // The registration, not the internal id. An operator knows the truck
          // by its plate; VH0028 means nothing to anyone holding a clipboard.
          Text(view.regNumber, style: const TextStyle(fontSize: 12)),
          // A stale alert says so, with what it last saw and when. Hiding the
          // uncertainty would present an unverified reading as current fact;
          // resolving it would assert a recovery nobody has observed.
          if (alert.isConditionStale)
            Text(
              'unconfirmed — last known '
              '${_formatValue(alert.kind, alert.lastKnownValue)}'
              '${alert.lastKnownAt == null ? '' : ' ${_ago(alert.lastKnownAt!)} ago'}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
            )
          else if (alert.lastKnownValue != null)
            Text(
              _formatValue(alert.kind, alert.lastKnownValue),
              style: TextStyle(fontSize: 11, color: colour),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: colour.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              alert.severity.wireName.toUpperCase(),
              style: TextStyle(
                color: colour,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => _openReasonSheet(context, alert),
          ),
        ],
      ),
    );
  }

  Future<void> _openReasonSheet(BuildContext context, Alert alert) async {
    final bloc = context.read<AlertsBloc>();

    final reason = await showModalBottomSheet<DismissalReason>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Dismiss ${_alertTitle(alert.kind)}?',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            // The three options in the order the brief specifies. The order is
            // not cosmetic: "I am on it" is the common case and goes first.
            for (final option in DismissalReason.values)
              ListTile(
                title: Text(option.label),
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (reason != null) bloc.add(AlertDismissed(alert, reason));
  }
}

class _NothingToSee extends StatelessWidget {
  const _NothingToSee();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 48, color: Color(0xFF1B7F4B)),
          SizedBox(height: 12),
          Text(
            'Nothing needs attention',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            'Dismissed alerts stay hidden until the condition worsens.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    ),
  );
}

String _alertTitle(AlertKind kind) => switch (kind) {
  AlertKind.batterySoc => 'Low battery',
  AlertKind.batteryOverheating => 'Battery overheating',
};

String _formatValue(AlertKind kind, double? value) {
  if (value == null) return '—';
  return switch (kind) {
    AlertKind.batterySoc => '${value.round()}%',
    AlertKind.batteryOverheating => '${value.toStringAsFixed(1)} °C',
  };
}

String _ago(DateTime at) => formatAge(DateTime.now().toUtc().difference(at));
