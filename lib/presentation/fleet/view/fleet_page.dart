/// Feature A — the fleet home.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants.dart';
import '../../../domain/entities/fleet_view.dart';
import '../../../domain/entities/vehicle_status.dart';
import '../../common/formatting.dart';
import '../../common/pills.dart';
import '../bloc/fleet_bloc.dart';

class FleetPage extends StatelessWidget {
  const FleetPage({
    required this.onVehicleTap,
    this.onAlertsTap,
    this.onSeedData,
    this.now,
    super.key,
  });

  /// Navigation is injected so this page stays testable without a router.
  final void Function(String vehicleId) onVehicleTap;

  final VoidCallback? onAlertsTap;

  /// Debug affordance: generate a round of telemetry.
  final Future<void> Function()? onSeedData;

  /// Injected for tests. Production passes null and the widget reads the wall
  /// clock — but only for *display* ages, never for a staleness decision, which
  /// has already been made in the domain.
  final DateTime? now;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Fleet'),
      actions: [
        if (onAlertsTap != null)
          BlocBuilder<FleetBloc, FleetState>(
            builder: (context, state) {
              final total = state.items.fold(
                0,
                (sum, item) => sum + item.openAlertCount,
              );
              final critical = state.items.any((i) => i.hasCriticalAlert);
              return IconButton(
                tooltip: 'Alerts',
                onPressed: onAlertsTap,
                icon: Badge(
                  isLabelVisible: total > 0,
                  backgroundColor: critical
                      ? const Color(0xFFB3261E)
                      : const Color(0xFFB26A00),
                  label: Text('$total'),
                  child: const Icon(Icons.notifications_outlined),
                ),
              );
            },
          ),
        if (onSeedData != null)
          IconButton(
            tooltip: 'Generate telemetry',
            icon: const Icon(Icons.bolt),
            onPressed: () async {
              await onSeedData!();
              if (context.mounted) {
                context.read<FleetBloc>().add(const FleetRequested());
              }
            },
          ),
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () =>
              context.read<FleetBloc>().add(const FleetRequested()),
        ),
      ],
    ),
    body: BlocBuilder<FleetBloc, FleetState>(
      builder: (context, state) => switch (state.status) {
        FleetStatus.initial ||
        FleetStatus.loading when state.items.isEmpty =>
          const Center(child: CircularProgressIndicator()),
        FleetStatus.failed => _Failed(message: state.error ?? 'Unknown error'),
        _ => Column(
          children: [
            _FilterBar(state: state),
            const Divider(height: 1),
            Expanded(
              child: state.isEmpty
                  ? _EmptyState(filter: state.filter)
                  : _FleetList(
                      items: state.items,
                      now: now,
                      onTap: onVehicleTap,
                    ),
            ),
          ],
        ),
      },
    ),
  );
}

/// Filter chips with live counts, computed in SQL.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.state});

  final FleetState state;

  @override
  Widget build(BuildContext context) {
    // "All" plus the four chips the brief names. `unknown` has no chip of its
    // own — those vehicles are counted in All and nowhere else, because
    // claiming they are stopped would be inventing data.
    const chips = [
      VehicleStatus.moving,
      VehicleStatus.idle,
      VehicleStatus.stopped,
      VehicleStatus.offline,
    ];

    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _Chip(
            label: 'All',
            count: state.totalVehicles,
            selected: state.filter == null,
            onTap: () =>
                context.read<FleetBloc>().add(const FleetFilterChanged(null)),
          ),
          for (final status in chips)
            _Chip(
              label: statusLabel(status),
              count: state.counts[status] ?? 0,
              selected: state.filter == status,
              onTap: () => context.read<FleetBloc>().add(
                FleetFilterChanged(status),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: FilterChip(
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      label: Text('$label  $count'),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    ),
  );
}

class _FleetList extends StatelessWidget {
  const _FleetList({required this.items, required this.onTap, this.now});

  final List<FleetListItem> items;
  final void Function(String vehicleId) onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final at = now ?? DateTime.now().toUtc();

    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        final socStale = item.socIsStale(
          at,
          FleetThresholds.signalStaleAfter,
        );

        return ListTile(
          onTap: () => onTap(item.vehicleId),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  item.regNumber,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              AlertBadge(
                count: item.openAlertCount,
                critical: item.hasCriticalAlert,
              ),
              const SizedBox(width: 6),
              StatusChip(status: item.status),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.model,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // A stale SOC is shown greyed with its age, never as a bare
                // current-looking number. "82%" from three hours ago,
                // presented plainly, is exactly the quiet lie this app exists
                // to avoid.
                _Metric(
                  value: item.soc == null
                      ? noValue
                      : '${item.soc!.round()}%',
                  faded: socStale,
                  suffix: socStale && item.socEventTs != null
                      ? ' · ${formatAge(at.difference(item.socEventTs!))}'
                      : null,
                ),
                const SizedBox(width: 12),
                _Metric(
                  value: item.rangeKm == null
                      ? noValue
                      : '${item.rangeKm!.round()} km',
                  faded: socStale,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, this.faded = false, this.suffix});

  final String value;
  final bool faded;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final colour = faded
        ? const Color(0xFF9CA3AF)
        : Theme.of(context).colorScheme.onSurface;
    return Text(
      '$value${suffix ?? ''}',
      style: TextStyle(
        fontSize: 12,
        color: colour,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.filter});

  final VehicleStatus? filter;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_shipping_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            filter == null
                ? 'No vehicles yet'
                : 'No ${statusLabel(filter!).toLowerCase()} vehicles',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            filter == null
                ? 'Generate telemetry from the toolbar to populate the fleet.'
                : 'Nothing matches this filter right now.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    ),
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: Color(0xFFB3261E)),
          const SizedBox(height: 12),
          const Text(
            'Could not read the fleet',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () =>
                context.read<FleetBloc>().add(const FleetRequested()),
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}
