import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../domain/models/cleared_call.dart';
import '../../../../domain/use_cases/fsl_time_utils.dart';
import '../../../core/widgets/phone_chips_bar.dart';
import '../../shell/view_models/app_shell_view_model.dart';

enum _CallbackFilterMode {
  all,
  cancelledOnly,
  redAlertOnly,
  needsCallback,
}

/// High-density Callback Log (`Cleared Calls`) view matching `fsl_tracker/dashboard.html`.
///
/// Displays all standard columns:
/// `[✓] | Cleared | Call | Territory | Member | Member phone | Benefit level | Type | Vehicle | Driver | Member waited | On scene | Flags`
/// with row-level `CANCELED` (`#3A2F14` bg, `#B9A77C` text, strikethrough Call ID),
/// `RED ALERT`, and `Territory` indicators.
class CallbackLogView extends StatefulWidget {
  const CallbackLogView({super.key, required this.viewModel});

  final AppShellViewModel viewModel;

  @override
  State<CallbackLogView> createState() => _CallbackLogViewState();
}

class _CallbackLogViewState extends State<CallbackLogView>
    with AutomaticKeepAliveClientMixin {
  _CallbackFilterMode _filterMode = _CallbackFilterMode.all;
  String? _selectedTerritory;
  String _searchQuery = '';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final allCalls = widget.viewModel.clearedCalls;

    final cancelledCount = allCalls.where((c) => c.isCancelled).length;
    final redAlertCount = allCalls.where((c) => c.isRedAlert).length;
    final needsCallbackCount = allCalls.where((c) => !c.calledBack).length;

    final territories = <String>{
      for (final c in allCalls)
        if (c.territory.trim().isNotEmpty) c.territory.trim(),
    }.toList()..sort();

    final query = _searchQuery.trim().toLowerCase();
    final filteredCalls = allCalls.where((c) {
      if (_filterMode == _CallbackFilterMode.cancelledOnly && !c.isCancelled) {
        return false;
      }
      if (_filterMode == _CallbackFilterMode.redAlertOnly && !c.isRedAlert) {
        return false;
      }
      if (_filterMode == _CallbackFilterMode.needsCallback && c.calledBack) {
        return false;
      }
      if (_selectedTerritory != null &&
          _selectedTerritory!.isNotEmpty &&
          c.territory.trim() != _selectedTerritory) {
        return false;
      }
      if (query.isNotEmpty) {
        final haystack = [
          c.callId,
          c.appointmentNumber,
          c.memberName ?? '',
          c.memberPhone ?? '',
          c.driverName,
          c.memberVehicle ?? '',
          c.workType ?? '',
          c.territory,
          c.benefitLevel ?? '',
        ].join(' ').toLowerCase();
        if (!haystack.contains(query)) return false;
      }
      return true;
    }).toList();

    return Container(
      color: const Color(0xFF14161A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Filter Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF1E2127),
              border: Border(
                bottom: BorderSide(color: Color(0xFF33373F)),
              ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Callback — cleared calls (last 12 h, newest first)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE8E8E8),
                  ),
                ),
                const SizedBox(width: 8),
                _buildFilterPill(
                  label: 'All (${allCalls.length})',
                  selected: _filterMode == _CallbackFilterMode.all,
                  onTap: () =>
                      setState(() => _filterMode = _CallbackFilterMode.all),
                ),
                _buildFilterPill(
                  label: 'Canceled ($cancelledCount)',
                  selected: _filterMode == _CallbackFilterMode.cancelledOnly,
                  activeColor: const Color(0xFFE5484D),
                  onTap: () => setState(
                    () => _filterMode = _CallbackFilterMode.cancelledOnly,
                  ),
                ),
                _buildFilterPill(
                  label: 'Red Alert ($redAlertCount)',
                  selected: _filterMode == _CallbackFilterMode.redAlertOnly,
                  activeColor: const Color(0xFFF5A623),
                  onTap: () => setState(
                    () => _filterMode = _CallbackFilterMode.redAlertOnly,
                  ),
                ),
                _buildFilterPill(
                  label: 'Unchecked ($needsCallbackCount)',
                  selected: _filterMode == _CallbackFilterMode.needsCallback,
                  activeColor: const Color(0xFF46A758),
                  onTap: () => setState(
                    () => _filterMode = _CallbackFilterMode.needsCallback,
                  ),
                ),
                if (territories.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF14161A),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: const Color(0xFF33373F)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: territories.contains(_selectedTerritory)
                              ? _selectedTerritory
                              : null,
                          isDense: true,
                          isExpanded: true,
                          hint: const Text(
                            'All Territories',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8B909C),
                            ),
                          ),
                          dropdownColor: const Color(0xFF1E2127),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFE8E8E8),
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text(
                                'All Territories',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            ...territories.map(
                              (t) => DropdownMenuItem<String?>(
                                value: t,
                                child: Text(
                                  t,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (val) =>
                              setState(() => _selectedTerritory = val),
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width: 230,
                  child: TextField(
                    onChanged: (val) => setState(() => _searchQuery = val),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Filter call, member, driver, vehicle...',
                      hintStyle: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8B909C),
                      ),
                      prefixIcon: const Icon(Icons.search, size: 15),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF14161A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(5),
                        borderSide: const BorderSide(color: Color(0xFF33373F)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(5),
                        borderSide: const BorderSide(color: Color(0xFF33373F)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Scrollable High-Density Table
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ClearedCallsTableSection(
                calls: filteredCalls,
                onToggleCalledBack:
                    widget.viewModel.toggleClearedCallCalledBack,
                showSectionHeader: false,
                initialLimit: 100,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color activeColor = const Color(0xFF3B82F6),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? activeColor.withValues(alpha: 0.22)
              : const Color(0xFF14161A),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? activeColor : const Color(0xFF33373F),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? const Color(0xFFE8E8E8)
                : const Color(0xFF8B909C),
          ),
        ),
      ),
    );
  }
}

/// Reusable high-density Callback table matching `fsl_tracker/dashboard.html`
/// (`#cleared-table`). Used both at the bottom of `DispatchDashboardView` and
/// inside `CallbackLogView`.
class ClearedCallsTableSection extends StatefulWidget {
  const ClearedCallsTableSection({
    super.key,
    required this.calls,
    required this.onToggleCalledBack,
    this.showSectionHeader = true,
    this.initialLimit = 20,
  });

  final List<ClearedCall> calls;
  final void Function(String uniqueKey) onToggleCalledBack;
  final bool showSectionHeader;
  final int initialLimit;

  @override
  State<ClearedCallsTableSection> createState() =>
      _ClearedCallsTableSectionState();
}

class _ClearedCallsTableSectionState extends State<ClearedCallsTableSection> {
  late int _displayLimit;

  @override
  void initState() {
    super.initState();
    _displayLimit = widget.initialLimit;
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

  static String _shortTerritoryLabel(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '–';
    final upper = t.toUpperCase();
    if (upper.contains('HOUSTON EMERGENCY AUTO RESCUE')) return 'HEART';
    if (upper.contains('HOUSTON TOWING')) return 'Houston Towing';
    if (upper.contains('ALL AMERICAN')) return 'All American';
    if (upper.contains('BMW')) return 'BMW';
    // Strip leading numeric territory code like "631252 - "
    return t.replaceFirst(RegExp(r'^\d+\s*[-–]\s*'), '');
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.calls.length;
    final visibleCalls = widget.calls.take(_displayLimit).toList();
    final remaining = total - visibleCalls.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showSectionHeader) ...[
          Row(
            children: [
              const Text(
                'Callback — cleared calls (last 12 h, newest first)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8B909C),
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '($total)',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8B909C),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E2127),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF33373F)),
          ),
          clipBehavior: Clip.antiAlias,
          child: visibleCalls.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                  child: Center(
                    child: Text(
                      'No cleared calls recorded in the last 12 hours.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF8B909C),
                      ),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const baseWidth = 1320.0;
                    final tableWidth = math.max(
                      constraints.maxWidth.isFinite
                          ? constraints.maxWidth
                          : baseWidth,
                      baseWidth,
                    );
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: tableWidth,
                        child: Table(
                          defaultVerticalAlignment:
                              TableCellVerticalAlignment.middle,
                          columnWidths: const {
                            0: FixedColumnWidth(34), // Checkbox
                            1: FixedColumnWidth(78), // Cleared
                            2: FixedColumnWidth(78), // Call
                            3: FixedColumnWidth(110), // Territory
                            4: FlexColumnWidth(1.2), // Member
                            5: FixedColumnWidth(148), // Member phone
                            6: FixedColumnWidth(92), // Benefit level
                            7: FlexColumnWidth(1.0), // Type
                            8: FlexColumnWidth(1.3), // Vehicle
                            9: FlexColumnWidth(1.1), // Driver
                            10: FixedColumnWidth(92), // Member waited
                            11: FixedColumnWidth(76), // On scene
                            12: FixedColumnWidth(116), // Flags
                          },
                          border: const TableBorder(
                            horizontalInside: BorderSide(
                              color: Color(0xFF33373F),
                              width: 1,
                            ),
                          ),
                          children: [
                            // Header Row
                            TableRow(
                              decoration: const BoxDecoration(
                                color: Color(0xFF252931),
                              ),
                              children: [
                                _th(''),
                                _th('Cleared'),
                                _th('Call'),
                                _th('Territory'),
                                _th('Member'),
                                _th('Member phone'),
                                _th('Benefit level'),
                                _th('Type'),
                                _th('Vehicle'),
                                _th('Driver'),
                                _th('Member waited', alignRight: true),
                                _th('On scene', alignRight: true),
                                _th('Flags'),
                              ],
                            ),
                            // Data Rows
                            for (final c in visibleCalls) _buildRow(context, c),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (remaining > 0) ...[
          const SizedBox(height: 8),
          Center(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                backgroundColor: const Color(0xFF1E2127),
                foregroundColor: const Color(0xFFE8E8E8),
                side: const BorderSide(color: Color(0xFF33373F)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
              ),
              onPressed: () {
                setState(() => _displayLimit += 20);
              },
              child: Text(
                'Load more ($remaining remaining)',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _th(String label, {bool alignRight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        label.toUpperCase(),
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: Color(0xFF8B909C),
        ),
      ),
    );
  }

  TableRow _buildRow(BuildContext context, ClearedCall c) {
    final clearedStr = FslTimeUtils.formatCentralTime(c.clearedAtEpochMs);
    final isCanceled = c.isCancelled;
    final isCalled = c.calledBack;

    // Match original dashboard.html: only canceled rows get a row background (#3A2F14)
    final Color? rowBg = isCanceled ? const Color(0xFF3A2F14) : null;
    final Color textColor = isCanceled
        ? const Color(0xFFB9A77C)
        : const Color(0xFFC9CDD6);
    final double opacity = isCalled ? 0.45 : 1.0;

    return TableRow(
      decoration: rowBg != null ? BoxDecoration(color: rowBg) : null,
      children: [
        // 0: Checkbox
        Opacity(
          opacity: opacity,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: isCalled,
                visualDensity: VisualDensity.compact,
                onChanged: (_) => widget.onToggleCalledBack(c.uniqueKey),
              ),
            ),
          ),
        ),
        // 1: Cleared
        _td(
          opacity: opacity,
          child: Text(
            clearedStr,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: textColor,
            ),
          ),
        ),
        // 2: Call ID (Single compact line, SA number in tooltip)
        _td(
          opacity: opacity,
          child: Tooltip(
            message: c.appointmentNumber.isNotEmpty
                ? '${c.callId} (${c.appointmentNumber})'
                : c.callId,
            child: InkWell(
              onTap: () => _copyText(context, c.callId, 'Call ID'),
              child: Text(
                c.callId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  decoration: isCanceled ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ),
        ),
        // 3: Territory (Short single-line badge/text, full name in tooltip)
        _td(
          opacity: opacity,
          child: Tooltip(
            message: c.territory,
            child: Text(
              _shortTerritoryLabel(c.territory),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: isCanceled
                    ? const Color(0xFFB9A77C)
                    : const Color(0xFF93C5FD),
              ),
            ),
          ),
        ),
        // 4: Member
        _td(
          opacity: opacity,
          child: Text(
            (c.memberName != null && c.memberName!.isNotEmpty)
                ? c.memberName!
                : '–',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: textColor),
          ),
        ),
        // 5: Member phone
        _td(
          opacity: opacity,
          child: (c.memberPhone != null && c.memberPhone!.trim().isNotEmpty)
              ? PhoneChipsBar(phones: [c.memberPhone!], compact: true)
              : const Text(
                  '–',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8B909C)),
                ),
        ),
        // 6: Benefit level
        _td(
          opacity: opacity,
          child: (c.benefitLevel != null && c.benefitLevel!.isNotEmpty)
              ? _buildBenefitPill(c.benefitLevel!)
              : const Text(
                  '–',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8B909C)),
                ),
        ),
        // 7: Type
        _td(
          opacity: opacity,
          child: Text(
            (c.workType != null && c.workType!.isNotEmpty) ? c.workType! : '–',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: textColor),
          ),
        ),
        // 8: Vehicle
        _td(
          opacity: opacity,
          child: Text(
            (c.memberVehicle != null && c.memberVehicle!.isNotEmpty)
                ? c.memberVehicle!
                : '–',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: textColor),
          ),
        ),
        // 9: Driver
        _td(
          opacity: opacity,
          child: Text(
            c.driverName.isNotEmpty ? c.driverName : '–',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: textColor),
          ),
        ),
        // 10: Member waited
        _td(
          opacity: opacity,
          alignRight: true,
          child: _buildMinutesText(
            minutes: c.waitDurationMin,
            defaultColor: textColor,
          ),
        ),
        // 11: On scene
        _td(
          opacity: opacity,
          alignRight: true,
          child: _buildMinutesText(
            minutes: c.onSceneDurationMin,
            defaultColor: textColor,
          ),
        ),
        // 12: Flags (CANCELED / RED ALERT)
        _td(
          opacity: opacity,
          child: Wrap(
            spacing: 4,
            runSpacing: 3,
            children: [
              if (isCanceled)
                _buildFlagPill(
                  'CANCELED',
                  fg: Colors.white,
                  bg: const Color(0xFFE5484D),
                ),
              if (c.isRedAlert)
                _buildFlagPill(
                  'RED ALERT',
                  fg: Colors.white,
                  bg: const Color(0xFFE5484D),
                  outlined: true,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _td({
    required double opacity,
    required Widget child,
    bool alignRight = false,
  }) {
    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4.5),
        child: Align(
          alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }

  Widget _buildBenefitPill(String benefit) {
    return Text(
      benefit,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Color(0xFFC9CDD6)),
    );
  }

  Widget _buildFlagPill(
    String text, {
    required Color fg,
    required Color bg,
    bool outlined = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(9),
        border: outlined ? Border.all(color: const Color(0x88FFFFFF)) : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildMinutesText({
    required int? minutes,
    required Color defaultColor,
  }) {
    if (minutes == null) {
      return const Text(
        '–',
        style: TextStyle(
          fontSize: 12,
          color: Color(0xFF8B909C),
        ),
      );
    }
    final label = minutes >= 60
        ? '${minutes ~/ 60}h ${minutes % 60}m'
        : '$minutes min';
    return Text(
      label,
      style: TextStyle(
        fontSize: 12,
        color: defaultColor,
      ),
    );
  }
}
