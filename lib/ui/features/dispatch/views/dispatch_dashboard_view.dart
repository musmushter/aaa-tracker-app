import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../domain/models/dispatch_alert.dart';
import '../../../../domain/models/dispatch_row.dart';
import '../../../../domain/use_cases/dispatch_report_builder.dart';
import '../../../core/widgets/phone_chips_bar.dart';
import '../../safety/views/camera_lightbox_dialog.dart';
import '../../shell/view_models/app_shell_view_model.dart';

/// FSL Dispatch Tracker view modeled directly after `fsl_tracker/dashboard.html`.
///
/// Features:
/// - Clean dark palette (`#14161A` bg, `#1E2127` card, `#33373F` border).
/// - Active Alerts box (`#3A1517` bg, `4px solid #E5484D` left border) or muted
///   `No active alerts.` bar.
/// - Territory-grouped high-density **Active Drivers Table** with all 13 columns:
///   `Driver | Call | Type | Status | Movement | In status | ETA (from feed) | Vehicle | Address | Dist (km) | GPS age | Flags | Report`
class DispatchDashboardView extends StatefulWidget {
  const DispatchDashboardView({super.key, required this.viewModel});

  final AppShellViewModel viewModel;

  @override
  State<DispatchDashboardView> createState() => _DispatchDashboardViewState();
}

class _DispatchDashboardViewState extends State<DispatchDashboardView>
    with AutomaticKeepAliveClientMixin {
  String _searchQuery = '';
  bool _alertsOnly = false;
  final Set<String> _recentlyCopiedCallIds = {};

  @override
  bool get wantKeepAlive => true;

  void _openTruckCameraPopup(BuildContext context, String motiveVehicleId) {
    final vm = widget.viewModel;
    final vehicle = vm.motiveVehicles
        .where((v) => v.id == motiveVehicleId)
        .firstOrNull;
    if (vehicle == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => CameraLightboxDialog(
        vehicles: [vehicle],
        initialIndex: 0,
        onRefreshCamera: vm.refreshSingleCamera,
        resolveLatestVehicle: (id) =>
            vm.motiveVehicles.where((v) => v.id == id).firstOrNull,
        autoRefreshIfMissing: true,
      ),
    );
  }

  Future<void> _copyDispatchReport(BuildContext context, DispatchRow row) async {
    final report = DispatchReportBuilder.buildReport(row);
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    setState(() => _recentlyCopiedCallIds.add(row.serviceAppointmentId));
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() => _recentlyCopiedCallIds.remove(row.serviceAppointmentId));
      }
    });
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied dispatch report for ${row.driverCleanName}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _copyText(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $label: $text'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final vm = widget.viewModel;
    final allRows = vm.dispatchRows;
    final alerts = vm.dispatchAlerts;
    final hasLive = vm.authService.hasFslSession && vm.lastFslError == null;

    final filteredRows = allRows.where((r) {
      if (_alertsOnly &&
          r.alerts.isEmpty &&
          !r.isRedAlert &&
          !r.etaIsStale) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchDriver = r.driverRawName.toLowerCase().contains(q);
        final matchCall = r.callId.toLowerCase().contains(q);
        final matchSa = r.appointmentNumber.toLowerCase().contains(q);
        final matchTerritory = r.territoryGroup.toLowerCase().contains(q);
        final matchStatus = r.status.toLowerCase().contains(q);
        final matchAddr = (r.pickupAddress ?? '').toLowerCase().contains(q);
        final matchTruck =
            (r.linkedTruck?.motiveVehicleName ?? '').toLowerCase().contains(q);
        if (!matchDriver &&
            !matchCall &&
            !matchSa &&
            !matchTerritory &&
            !matchStatus &&
            !matchAddr &&
            !matchTruck) {
          return false;
        }
      }
      return true;
    }).toList();

    // Group active rows by territoryGroup (matching dashboard.html lines 473-491)
    final groups = <String, List<DispatchRow>>{};
    for (final r in filteredRows) {
      final g = r.territoryGroup.trim().isNotEmpty
          ? r.territoryGroup.trim()
          : 'Other';
      groups.putIfAbsent(g, () => <DispatchRow>[]).add(r);
    }
    final sortedGroupNames = groups.keys.toList()..sort();
    for (final g in sortedGroupNames) {
      groups[g]!.sort((a, b) {
        final aAlarm = a.alerts.isNotEmpty ? 0 : 1;
        final bAlarm = b.alerts.isNotEmpty ? 0 : 1;
        if (aAlarm != bAlarm) return aAlarm.compareTo(bAlarm);
        return b.statusDurationMin.compareTo(a.statusDurationMin);
      });
    }

    return Container(
      color: const Color(0xFF14161A),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Header Bar (matching dashboard.html <header>)
            Container(
              padding: const EdgeInsets.only(bottom: 10),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF33373F)),
                ),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Flexible(
                        child: Text(
                          'FSL Dispatch Tracker',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE8E8E8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: hasLive
                              ? const Color(0x2E46A758)
                              : const Color(0x2EF5A623),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          hasLive ? 'live' : 'no data',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: hasLive
                                ? const Color(0xFF86EFAC)
                                : const Color(0xFFFCD34D),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ValueListenableBuilder<int>(
                        valueListenable: vm.clockTickNotifier,
                        builder: (context, _, _) {
                          return Text(
                            '${vm.accountClockText}  •  ${allRows.length} active',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8B909C),
                            ),
                          );
                        },
                      ),
                      if (vm.lastFslUpdatedLabel != null)
                        Text(
                          'Updated ${vm.lastFslUpdatedLabel}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8B909C),
                          ),
                        ),
                      SizedBox(
                        width: 220,
                        child: TextField(
                          onChanged: (v) =>
                              setState(() => _searchQuery = v.trim()),
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'Filter driver, call, territory...',
                            hintStyle: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8B909C),
                            ),
                            prefixIcon: const Icon(Icons.search, size: 15),
                            isDense: true,
                            filled: true,
                            fillColor: const Color(0xFF1E2127),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                              borderSide: const BorderSide(
                                color: Color(0xFF33373F),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                              borderSide: const BorderSide(
                                color: Color(0xFF33373F),
                              ),
                            ),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () =>
                            setState(() => _alertsOnly = !_alertsOnly),
                        borderRadius: BorderRadius.circular(5),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _alertsOnly
                                ? const Color(0x38E5484D)
                                : const Color(0xFF1E2127),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: _alertsOnly
                                  ? const Color(0xFFE5484D)
                                  : const Color(0xFF33373F),
                            ),
                          ),
                          child: Text(
                            'Alerts Only (${alerts.length})',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: _alertsOnly
                                  ? const Color(0xFFFF8B8E)
                                  : const Color(0xFF8B909C),
                            ),
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: const Color(0xFF1E2127),
                          side: const BorderSide(color: Color(0xFF33373F)),
                        ),
                        onPressed: vm.isFslLoading
                            ? null
                            : () => vm.pollFslNow(fullShiftReload: false),
                        icon: vm.isFslLoading
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync, size: 14),
                        label: const Text(
                          'Sync',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // 2. Active Alerts Box (matching dashboard.html .alerts-box)
            _buildAlertsBox(alerts),

            const SizedBox(height: 14),

            // 3. Active Drivers Table Grouped by Service Territory
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E2127),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF33373F)),
              ),
              clipBehavior: Clip.antiAlias,
              child: filteredRows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 28,
                        horizontal: 16,
                      ),
                      child: Center(
                        child: Text(
                          vm.authService.hasFslSession
                              ? 'No active drivers on calls.'
                              : 'Sign in to Salesforce FSL in Connections (or click Auto-Detect from Open Browser) to start tracking.',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF8B909C),
                          ),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const baseWidth = 1480.0;
                        final tableWidth = math.max(
                          constraints.maxWidth.isFinite
                              ? constraints.maxWidth
                              : baseWidth,
                          baseWidth,
                        );
                        final scale = tableWidth / baseWidth;
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: tableWidth,
                            child: _buildActiveDriversTable(
                              context,
                              sortedGroupNames,
                              groups,
                              tableWidth: tableWidth,
                              scale: scale,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertsBox(List<DispatchAlert> alerts) {
    if (alerts.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2127),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF33373F)),
        ),
        child: const Text(
          'No active alerts.',
          style: TextStyle(fontSize: 12.5, color: Color(0xFF8B909C)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1517),
        borderRadius: BorderRadius.circular(6),
        border: const Border(
          top: BorderSide(color: Color(0xFFE5484D)),
          right: BorderSide(color: Color(0xFFE5484D)),
          bottom: BorderSide(color: Color(0xFFE5484D)),
          left: BorderSide(color: Color(0xFFE5484D), width: 4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ACTIVE ALERTS (${alerts.length})',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: Color(0xFFFF8B8E),
            ),
          ),
          const SizedBox(height: 6),
          ...alerts.map((a) {
            final cleanDriver = a.driverName.split('*').first.trim();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFFE8E8E8),
                  ),
                  children: [
                    TextSpan(
                      text: '[${a.type.code}] ',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF8B8E),
                      ),
                    ),
                    TextSpan(
                      text: cleanDriver,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: ' (Call ${a.callId}): ${a.detail}',
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildActiveDriversTable(
    BuildContext context,
    List<String> sortedGroupNames,
    Map<String, List<DispatchRow>> groups, {
    required double tableWidth,
    required double scale,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Table Header
        Container(
          width: tableWidth,
          decoration: const BoxDecoration(
            color: Color(0xFF252931),
            border: Border(bottom: BorderSide(color: Color(0xFF33373F))),
          ),
          child: Row(
            children: [
              _headerCell('Driver', width: 280 * scale),
              _headerCell('Call', width: 82 * scale),
              _headerCell('Type', width: 105 * scale),
              _headerCell('Status', width: 92 * scale),
              _headerCell('Movement', width: 98 * scale),
              _headerCell('In status', width: 70 * scale, alignRight: true),
              _headerCell('ETA', width: 98 * scale),
              _headerCell('Vehicle', width: 145 * scale),
              _headerCell('Address', width: 220 * scale),
              _headerCell('Dist (km)', width: 64 * scale, alignRight: true),
              _headerCell('GPS age', width: 62 * scale, alignRight: true),
              _headerCell('Flags', width: 100 * scale),
              _headerCell('', width: 64 * scale),
            ],
          ),
        ),
        // Territory Groups & Driver Rows
        for (final g in sortedGroupNames) ...[
          // Territory Group Header Row (matching tr.group-row td)
          Container(
            width: tableWidth,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF2A2E37),
              border: Border(bottom: BorderSide(color: Color(0xFF33373F))),
            ),
            child: Text(
              '${g.toUpperCase()} — ${groups[g]!.length} driver(s)',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFFE8E8E8),
              ),
            ),
          ),
          for (final row in groups[g]!)
            _buildDriverDataRow(
              context,
              row,
              tableWidth: tableWidth,
              scale: scale,
            ),
        ],
      ],
    );
  }

  Widget _headerCell(String text, {required double width, bool alignRight = false}) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Text(
          text.toUpperCase(),
          textAlign: alignRight ? TextAlign.right : TextAlign.left,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: Color(0xFF8B909C),
          ),
        ),
      ),
    );
  }

  Widget _buildDriverDataRow(
    BuildContext context,
    DispatchRow r, {
    required double tableWidth,
    required double scale,
  }) {
    final hasAlarm = r.alerts.isNotEmpty;
    // Match original dashboard.html: only active alerts highlight the row (#3A1517);
    // RED ALERT services use the redmark badge in Flags without a yellow row highlight.
    final Color? rowBg = hasAlarm ? const Color(0xFF3A1517) : null;

    final link = r.linkedTruck;
    final isCopied = _recentlyCopiedCallIds.contains(r.serviceAppointmentId);

    return Container(
      width: tableWidth,
      decoration: BoxDecoration(
        color: rowBg,
        border: const Border(bottom: BorderSide(color: Color(0xFF33373F))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Driver (Name + Cam badge inline on Row 1, compact phones on Row 2)
          _dataCell(
            width: 280 * scale,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      r.driverCleanName,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE8E8E8),
                      ),
                    ),
                    if (link != null)
                      InkWell(
                        onTap: () => _openTruckCameraPopup(
                          context,
                          link.motiveVehicleId,
                        ),
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x2E46A758),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: const Color(
                                0xFF46A758,
                              ).withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.videocam_rounded,
                                size: 10.5,
                                color: Color(0xFF86EFAC),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                link.motiveUnitNumber,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF86EFAC),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (r.driverPhones.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  PhoneChipsBar(phones: r.driverPhones, compact: true),
                ],
              ],
            ),
          ),

          // 2. Call (Single compact line like original dashboard.html, SA number on tooltip)
          _dataCell(
            width: 82 * scale,
            child: Tooltip(
              message: r.appointmentNumber.isNotEmpty
                  ? '${r.callId} (${r.appointmentNumber})'
                  : r.callId,
              child: InkWell(
                onTap: () => _copyText(context, r.callId, 'Call ID'),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      r.callId,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFE8E8E8),
                      ),
                    ),
                    if (r.isChainSecondLeg)
                      _pill(
                        '2nd',
                        fg: const Color(0xFFFF7D81),
                        bg: const Color(0x22E5484D),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // 3. Type
          _dataCell(
            width: 105 * scale,
            child: Text(
              r.workType.isNotEmpty ? r.workType : '–',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE8E8E8)),
            ),
          ),

          // 4. Status
          _dataCell(
            width: 92 * scale,
            child: _buildStatusPill(r.status),
          ),

          // 5. Movement
          _dataCell(
            width: 98 * scale,
            child: _buildMovementPill(r.movementState, r.movementDurationMin),
          ),

          // 6. In status
          _dataCell(
            width: 70 * scale,
            alignRight: true,
            child: _buildInStatusCell(r.statusDurationMin),
          ),

          // 7. ETA (Only actual target time, e.g. "7:34 PM" or "6:50–6:55 PM")
          _dataCell(
            width: 98 * scale,
            child: _buildEtaCell(r),
          ),

          // 8. Vehicle
          _dataCell(
            width: 145 * scale,
            child: Text(
              (r.memberVehicle != null && r.memberVehicle!.isNotEmpty)
                  ? r.memberVehicle!
                  : '–',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE8E8E8)),
            ),
          ),

          // 9. Address (Pickup + Drop-off)
          _dataCell(
            width: 220 * scale,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (r.pickupAddress != null && r.pickupAddress!.isNotEmpty)
                      ? r.pickupAddress!
                      : '–',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFE8E8E8),
                  ),
                ),
                if (r.dropoffAddress != null &&
                    r.dropoffAddress!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    '↓ ${r.dropoffAddress}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8B909C),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 10. Dist (km)
          _dataCell(
            width: 64 * scale,
            alignRight: true,
            child: Text(
              r.distanceToCallKm != null
                  ? r.distanceToCallKm!.toStringAsFixed(1)
                  : '–',
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Color(0xFFE8E8E8),
              ),
            ),
          ),

          // 11. GPS age (green <=10m, red >10m matching original .ok / .stale)
          _dataCell(
            width: 62 * scale,
            alignRight: true,
            child: Text(
              r.gpsAgeMin != null ? '${r.gpsAgeMin!.round()}m' : '–',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: (r.gpsAgeMin != null && r.gpsAgeMin! > 10)
                    ? FontWeight.w700
                    : FontWeight.normal,
                color: r.gpsAgeMin == null
                    ? const Color(0xFF8B909C)
                    : (r.gpsAgeMin! > 10
                          ? const Color(0xFFE5484D)
                          : const Color(0xFF46A758)),
              ),
            ),
          ),

          // 12. Flags
          _dataCell(
            width: 100 * scale,
            child: _buildFlagsCell(r),
          ),

          // 13. Report
          _dataCell(
            width: 64 * scale,
            child: InkWell(
              onTap: () => _copyDispatchReport(context, r),
              borderRadius: BorderRadius.circular(5),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2127),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isCopied
                        ? const Color(0xFF46A758)
                        : const Color(0xFF33373F),
                  ),
                ),
                child: Text(
                  isCopied ? 'Copied!' : 'Report',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: isCopied
                        ? const Color(0xFF46A758)
                        : const Color(0xFFE8E8E8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dataCell({
    required double width,
    required Widget child,
    bool alignRight = false,
  }) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Align(
          alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }

  Widget _buildStatusPill(String status) {
    final s = status.toLowerCase().replaceAll(' ', '');
    Color fg = const Color(0xFFB9BEC7);
    Color bg = const Color(0x228B909C);
    if (s.startsWith('dispatched')) {
      fg = const Color(0xFFFF7D81);
      bg = const Color(0x22E5484D);
    } else if (s.startsWith('enroute')) {
      fg = const Color(0xFF6CD96C);
      bg = const Color(0x22228B22);
    } else if (s.startsWith('onlocation') ||
        s.startsWith('tow') ||
        s.startsWith('intow')) {
      fg = const Color(0xFF7AB3E8);
      bg = const Color(0x223A6EA5);
    } else if (s.startsWith('onrap')) {
      fg = const Color(0xFFB39DDB);
      bg = const Color(0x226B4FA0);
    } else if (s.startsWith('spotted')) {
      fg = const Color(0xFFFFC35C);
      bg = const Color(0x22F5A623);
    }
    return _pill(status, fg: fg, bg: bg);
  }

  Widget _buildMovementPill(String? state, int? durationMin) {
    if (state == null || state.isEmpty) {
      return const Text(
        '–',
        style: TextStyle(fontSize: 12, color: Color(0xFF8B909C)),
      );
    }
    if (state == 'MOVING') {
      return _pill(
        'MOVING',
        fg: const Color(0xFF6CD96C),
        bg: const Color(0x22228B22),
        bold: true,
      );
    }
    if (state == 'STANDSTILL') {
      return _pill(
        'STANDSTILL',
        fg: const Color(0xFFFF7D81),
        bg: const Color(0x22E5484D),
        bold: true,
      );
    }
    if (state == 'AT LOC' || state == 'AT DROP OFF') {
      return _pill(
        state,
        fg: const Color(0xFF7AB3E8),
        bg: const Color(0x223A6EA5),
        bold: true,
      );
    }
    return Text(
      state,
      style: const TextStyle(fontSize: 11.5, color: Color(0xFFE8E8E8)),
    );
  }

  Widget _buildInStatusCell(double durationMin) {
    final mins = durationMin.round();
    final label = mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '$mins min';
    return Text(
      label,
      style: const TextStyle(
        fontSize: 12,
        color: Color(0xFFE8E8E8),
      ),
    );
  }

  Widget _buildEtaCell(DispatchRow r) {
    final windowText = r.etaWindowText ?? r.etaText;
    if (windowText == null || windowText.isEmpty) {
      return const Text(
        '–',
        style: TextStyle(
          fontSize: 12,
          color: Color(0xFF8B909C),
        ),
      );
    }
    return Tooltip(
      message: r.etaIsStale
          ? '${r.etaText ?? windowText} (Stale: ${r.etaStaleReason ?? "check"})'
          : (r.etaText ?? windowText),
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFE8E8E8),
          ),
          children: [
            TextSpan(text: windowText),
            if (r.etaIsStale)
              const TextSpan(
                text: ' *',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE5484D),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlagsCell(DispatchRow r) {
    final pills = <Widget>[];
    if (r.isRedAlert) {
      pills.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0x88FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0xCCE5484D),
                blurRadius: 6,
              ),
            ],
          ),
          child: const Text(
            'RED ALERT',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    for (final a in r.alerts) {
      final label = switch (a.type) {
        DispatchAlertType.dispatchOverdue => 'DISPATCH>10m',
        DispatchAlertType.standingStill => 'STILL>10m',
        DispatchAlertType.etaExpired => 'ETA LATE',
      };
      pills.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    if (pills.isEmpty) {
      return const Text(
        '',
        style: TextStyle(fontSize: 12, color: Color(0xFF8B909C)),
      );
    }
    return Wrap(spacing: 3, runSpacing: 3, children: pills);
  }

  Widget _pill(
    String text, {
    required Color fg,
    required Color bg,
    bool bold = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}
