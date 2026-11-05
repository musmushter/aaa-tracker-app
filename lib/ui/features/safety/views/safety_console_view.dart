import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../data/services/motive_report_share_service.dart';
import '../../../../domain/models/motive_vehicle.dart';
import '../../shell/view_models/app_shell_view_model.dart';
import 'camera_lightbox_dialog.dart';

enum SafetySortOption {
  motionAndSpeed('Status: In Transit → Idling'),
  newestSnapshot('Updated: Newest First'),
  oldestSnapshot('Updated: Oldest First'),
  unitName('Unit Name: A → Z'),
  driverName('Driver Name: A → Z');

  const SafetySortOption(this.label);
  final String label;
}

/// Redesigned Motive Safety Console view.
///
/// - Persistent filters across tab switches (`IndexedStack` + `SharedPreferences`).
/// - Multi-Organization selector (`HEART`, `Houston Towing`, etc.) and
///   Multi-Group / Fleet selector (`HEART`, `ALL AMERICAN`, `BMW`, `HOUSTON TOWING`, `Unassigned`).
/// - True `16:9` camera frames (`BoxFit.contain`) for both the main Driver Cam
///   and secondary thumbnails (`Road Cam`, etc.) so zero pixels are ever
///   squished or cropped.
/// - Single-button cross-device `Report` action that stitches the views and
///   copies the stitched image + `Driver + URL` text onto the system clipboard.
class SafetyConsoleView extends StatefulWidget {
  const SafetyConsoleView({super.key, required this.viewModel});

  final AppShellViewModel viewModel;

  @override
  State<SafetyConsoleView> createState() => _SafetyConsoleViewState();
}

class _SafetyConsoleViewState extends State<SafetyConsoleView>
    with AutomaticKeepAliveClientMixin {
  static const String _prefOrgsKey = 'safety_selected_orgs_v2';
  static const String _prefGroupsKey = 'safety_selected_groups_v2';
  static const String _prefMotionsKey = 'safety_selected_motions_v2';
  static const String _prefHideOffKey = 'safety_hide_powered_off_v2';
  static const String _prefOnCallKey = 'safety_only_on_call_v2';
  static const String _prefSnapshotsKey = 'safety_only_snapshots_v2';
  static const String _prefSortKey = 'safety_sort_option_v2';

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// Empty set means "All Organizations".
  final Set<String> _selectedOrgs = {};

  /// Empty set means "All Groups".
  final Set<String> _selectedGroups = {};

  final Set<VehicleMotionCategory> _selectedMotions = {
    VehicleMotionCategory.transit,
    VehicleMotionCategory.idle,
  };

  bool _onlyOnCall = false;
  bool _onlyWithSnapshots = false;
  bool _hidePoweredOff = true;
  SafetySortOption _sortOption = SafetySortOption.motionAndSpeed;
  final Set<String> _reportingVehicleIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadSavedFilterPrefs();
  }

  Future<void> _loadSavedFilterPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOrgs = prefs.getStringList(_prefOrgsKey);
      final savedGroups = prefs.getStringList(_prefGroupsKey);
      final savedMotions = prefs.getStringList(_prefMotionsKey);
      final savedHideOff = prefs.getBool(_prefHideOffKey);
      final savedOnCall = prefs.getBool(_prefOnCallKey);
      final savedSnapshots = prefs.getBool(_prefSnapshotsKey);
      final savedSort = prefs.getString(_prefSortKey);

      if (!mounted) return;
      setState(() {
        if (savedOrgs != null) {
          _selectedOrgs
            ..clear()
            ..addAll(savedOrgs);
        }
        if (savedGroups != null) {
          _selectedGroups
            ..clear()
            ..addAll(savedGroups);
        }
        if (savedMotions != null) {
          _selectedMotions.clear();
          for (final key in savedMotions) {
            for (final m in VehicleMotionCategory.values) {
              if (m.key == key) _selectedMotions.add(m);
            }
          }
        }
        if (savedHideOff != null) _hidePoweredOff = savedHideOff;
        if (savedOnCall != null) _onlyOnCall = savedOnCall;
        if (savedSnapshots != null) _onlyWithSnapshots = savedSnapshots;
        if (savedSort != null) {
          for (final opt in SafetySortOption.values) {
            if (opt.name == savedSort) _sortOption = opt;
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _saveFilterPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefOrgsKey, _selectedOrgs.toList());
      await prefs.setStringList(_prefGroupsKey, _selectedGroups.toList());
      await prefs.setStringList(
        _prefMotionsKey,
        _selectedMotions.map((m) => m.key).toList(),
      );
      await prefs.setBool(_prefHideOffKey, _hidePoweredOff);
      await prefs.setBool(_prefOnCallKey, _onlyOnCall);
      await prefs.setBool(_prefSnapshotsKey, _onlyWithSnapshots);
      await prefs.setString(_prefSortKey, _sortOption.name);
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _hasNonDefaultFilters =>
      _searchQuery.isNotEmpty ||
      _selectedOrgs.isNotEmpty ||
      _selectedGroups.isNotEmpty ||
      _onlyOnCall ||
      _onlyWithSnapshots ||
      !_hidePoweredOff ||
      _selectedMotions.length != 2 ||
      !_selectedMotions.contains(VehicleMotionCategory.transit) ||
      !_selectedMotions.contains(VehicleMotionCategory.idle);

  void _resetFilters() {
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      _selectedOrgs.clear();
      _selectedGroups.clear();
      _selectedMotions
        ..clear()
        ..addAll([VehicleMotionCategory.transit, VehicleMotionCategory.idle]);
      _onlyOnCall = false;
      _onlyWithSnapshots = false;
      _hidePoweredOff = true;
      _sortOption = SafetySortOption.motionAndSpeed;
    });
    _saveFilterPrefs();
    widget.viewModel.clearFocusedVehicle();
  }

  Future<void> _handleSingleButtonReport(
    BuildContext context,
    MotiveVehicle vehicle,
  ) async {
    if (_reportingVehicleIds.contains(vehicle.id)) return;
    setState(() => _reportingVehicleIds.add(vehicle.id));
    try {
      final result = await MotiveReportShareService.executeSingleButtonReport(
        vehicle,
        onEnsureSnapshots: widget.viewModel.refreshSingleCamera,
      );
      if (!context.mounted) return;
      if (!result.sharedViaNativeSheet) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        final controller = messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
            content: Text(
              result.copiedImageToClipboard
                  ? 'WhatsApp Ready: 1st Ctrl+V pastes stitched photo • 2nd Ctrl+V (or Middle-Click) pastes Driver & URL caption'
                  : (result.hasStitchedImage
                        ? 'Report text copied • Stitched image saved'
                        : 'Report text copied to clipboard (Ctrl+V)'),
            ),
            action: SnackBarAction(
              label: 'Copy Text',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.reportText));
              },
            ),
          ),
        );
        Timer(const Duration(seconds: 4), () {
          try {
            controller.close();
          } catch (_) {}
        });
      }
    } finally {
      if (mounted) {
        setState(() => _reportingVehicleIds.remove(vehicle.id));
      }
    }
  }

  Future<void> _openInMotiveWeb(MotiveVehicle vehicle) async {
    final uri = Uri.parse(vehicle.liveMotiveUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  int _motionRank(VehicleMotionCategory cat) {
    switch (cat) {
      case VehicleMotionCategory.transit:
        return 0;
      case VehicleMotionCategory.idle:
        return 1;
      case VehicleMotionCategory.stationary:
        return 2;
    }
  }

  void _showMultiGroupDialog(
    BuildContext context,
    List<String> sortedGroups,
    Map<String, int> groupCounts,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2127),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              title: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Select Fleet Groups / Associations',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          setState(() {
                            _selectedGroups
                              ..clear()
                              ..addAll(sortedGroups);
                          });
                          _saveFilterPrefs();
                          setModalState(() {});
                        },
                        child: const Text('Select All'),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          setState(() => _selectedGroups.clear());
                          _saveFilterPrefs();
                          setModalState(() {});
                        },
                        child: const Text('All (No Filter)'),
                      ),
                    ],
                  ),
                ],
              ),
              content: SizedBox(
                width: 380,
                child: ListView(
                  shrinkWrap: true,
                  children: sortedGroups.map((g) {
                    final checked = _selectedGroups.contains(g);
                    final count = groupCounts[g] ?? 0;
                    return CheckboxListTile(
                      dense: true,
                      value: checked,
                      title: Text(
                        '$g ($count)',
                        style: const TextStyle(fontSize: 13),
                      ),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedGroups.add(g);
                          } else {
                            _selectedGroups.remove(g);
                          }
                        });
                        _saveFilterPrefs();
                        setModalState(() {});
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showOrgFilterDialog(
    BuildContext context,
    List<String> sortedOrgs,
    Map<String, int> orgCounts,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2127),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              title: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Filter by Organization',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _selectedOrgs.clear());
                      _saveFilterPrefs();
                      setModalState(() {});
                    },
                    child: const Text('All Orgs'),
                  ),
                ],
              ),
              content: SizedBox(
                width: 360,
                child: ListView(
                  shrinkWrap: true,
                  children: sortedOrgs.map((org) {
                    final checked = _selectedOrgs.contains(org);
                    final count = orgCounts[org] ?? 0;
                    return CheckboxListTile(
                      dense: true,
                      value: checked,
                      title: Text(
                        '$org ($count)',
                        style: const TextStyle(fontSize: 13),
                      ),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedOrgs.add(org);
                          } else {
                            _selectedOrgs.remove(org);
                          }
                        });
                        _saveFilterPrefs();
                        setModalState(() {});
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showStatusFiltersDialog(
    BuildContext context,
    Map<VehicleMotionCategory, int> motionCounts,
    int onCallCount,
    int withSnapshotsCount,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2127),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              title: Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Motion & Status Filters',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedMotions.clear();
                        _onlyOnCall = false;
                        _onlyWithSnapshots = false;
                        _hidePoweredOff = true;
                      });
                      _saveFilterPrefs();
                      setModalState(() {});
                    },
                    child: const Text('Reset Defaults'),
                  ),
                ],
              ),
              content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 12, bottom: 4),
                      child: Text(
                        'VEHICLE MOTION',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF8B909C),
                        ),
                      ),
                    ),
                    ...VehicleMotionCategory.values.map((m) {
                      final checked = _selectedMotions.contains(m);
                      final count = motionCounts[m] ?? 0;
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        title: Text(
                          '${m.label} ($count)',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selectedMotions.add(m);
                            } else {
                              _selectedMotions.remove(m);
                            }
                          });
                          _saveFilterPrefs();
                          setModalState(() {});
                        },
                      );
                    }),
                    const Divider(color: Color(0xFF33373F), height: 16),
                    const Padding(
                      padding: EdgeInsets.only(left: 12, bottom: 4),
                      child: Text(
                        'STATUS & SNAPSHOTS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF8B909C),
                        ),
                      ),
                    ),
                    SwitchListTile(
                      dense: true,
                      value: _onlyOnCall,
                      title: Text(
                        'On Call Only ($onCallCount)',
                        style: const TextStyle(fontSize: 13),
                      ),
                      onChanged: (val) {
                        setState(() => _onlyOnCall = val);
                        _saveFilterPrefs();
                        setModalState(() {});
                      },
                    ),
                    SwitchListTile(
                      dense: true,
                      value: _onlyWithSnapshots,
                      title: Text(
                        'Captured Snapshots Only ($withSnapshotsCount)',
                        style: const TextStyle(fontSize: 13),
                      ),
                      onChanged: (val) {
                        setState(() => _onlyWithSnapshots = val);
                        _saveFilterPrefs();
                        setModalState(() {});
                      },
                    ),
                    SwitchListTile(
                      dense: true,
                      value: _hidePoweredOff,
                      title: const Text(
                        'Hide Powered Off Vehicles',
                        style: TextStyle(fontSize: 13),
                      ),
                      onChanged: (val) {
                        setState(() => _hidePoweredOff = val);
                        _saveFilterPrefs();
                        setModalState(() {});
                      },
                    ),
                    ],
                  ),
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final vm = widget.viewModel;
    final allVehicles = vm.motiveVehicles;
    final focusedId = vm.focusedMotiveVehicleId;

    // 1. Compute dynamic Organization counts & Group counts across the fleet
    final orgCounts = <String, int>{};
    for (final account in vm.authService.motiveAccounts) {
      orgCounts.putIfAbsent(account.organizationName, () => 0);
    }
    final groupCounts = <String, int>{};
    final motionCounts = <VehicleMotionCategory, int>{
      for (final m in VehicleMotionCategory.values) m: 0,
    };
    int onCallCount = 0;
    int withSnapshotsCount = 0;

    for (final v in allVehicles) {
      if (_hidePoweredOff && v.isPoweredOff) continue;
      final org = v.organizationName.trim().isNotEmpty
          ? v.organizationName.trim()
          : 'Motive';
      orgCounts[org] = (orgCounts[org] ?? 0) + 1;
    }

    final sortedOrgs = orgCounts.keys.toList()..sort();
    final activeOrgs = _selectedOrgs.intersection(sortedOrgs.toSet());

    for (final v in allVehicles) {
      if (_hidePoweredOff && v.isPoweredOff) continue;
      if (activeOrgs.isNotEmpty &&
          !activeOrgs.contains(v.organizationName.trim())) {
        continue;
      }
      final grp = v.associationGroup.trim().isNotEmpty
          ? v.associationGroup.trim()
          : 'Unassigned';
      groupCounts[grp] = (groupCounts[grp] ?? 0) + 1;
      motionCounts[v.motionCategory] =
          (motionCounts[v.motionCategory] ?? 0) + 1;
      if (v.linkedFslDriver != null) onCallCount++;
      if (v.hasImages) withSnapshotsCount++;
    }

    final sortedGroups = groupCounts.keys.toList()..sort();
    final activeGroups = _selectedGroups.intersection(sortedGroups.toSet());

    // 2. Filter vehicles (and compute auto-refresh target pool before search/snapshot-only narrowing)
    final autoRefreshPool = allVehicles.where((v) {
      if (focusedId != null && v.id == focusedId) return true;
      if (_hidePoweredOff && v.isPoweredOff) return false;
      if (activeOrgs.isNotEmpty &&
          !activeOrgs.contains(v.organizationName.trim())) {
        return false;
      }
      final grp = v.associationGroup.trim().isNotEmpty
          ? v.associationGroup.trim()
          : 'Unassigned';
      if (activeGroups.isNotEmpty && !activeGroups.contains(grp)) {
        return false;
      }
      if (_onlyOnCall && v.linkedFslDriver == null) return false;
      if (_selectedMotions.isNotEmpty &&
          !_selectedMotions.contains(v.motionCategory)) {
        return false;
      }
      return true;
    }).toList();

    final filtered = autoRefreshPool.where((v) {
      if (focusedId != null && v.id == focusedId) return true;
      if (_onlyWithSnapshots && !v.hasImages) return false;
      if (_searchQuery.isNotEmpty) {
        final grp = v.associationGroup.trim().isNotEmpty
            ? v.associationGroup.trim()
            : 'Unassigned';
        final q = _searchQuery.toLowerCase();
        final matchName = v.name.toLowerCase().contains(q);
        final matchDrv = (v.effectiveDriverName ?? '')
            .toLowerCase()
            .contains(q);
        final matchGrp = grp.toLowerCase().contains(q);
        final matchOrg = v.organizationName.toLowerCase().contains(q);
        if (!matchName && !matchDrv && !matchGrp && !matchOrg) {
          return false;
        }
      }
      return true;
    }).toList();

    // 3. Sort vehicles
    filtered.sort((a, b) {
      if (focusedId != null) {
        if (a.id == focusedId) return -1;
        if (b.id == focusedId) return 1;
      }
      switch (_sortOption) {
        case SafetySortOption.motionAndSpeed:
          final rankCmp = _motionRank(
            a.motionCategory,
          ).compareTo(_motionRank(b.motionCategory));
          if (rankCmp != 0) return rankCmp;
          final speedCmp = b.speedMph.compareTo(a.speedMph);
          if (speedCmp != 0) return speedCmp;
          return a.name.compareTo(b.name);
        case SafetySortOption.newestSnapshot:
          final tsA = a.lastRefreshedEpochMs ?? 0;
          final tsB = b.lastRefreshedEpochMs ?? 0;
          final tsCmp = tsB.compareTo(tsA);
          if (tsCmp != 0) return tsCmp;
          return a.name.compareTo(b.name);
        case SafetySortOption.oldestSnapshot:
          final tsA = a.lastRefreshedEpochMs ?? 0;
          final tsB = b.lastRefreshedEpochMs ?? 0;
          final tsCmp = tsA.compareTo(tsB);
          if (tsCmp != 0) return tsCmp;
          return a.name.compareTo(b.name);
        case SafetySortOption.unitName:
          return a.name.compareTo(b.name);
        case SafetySortOption.driverName:
          final dA = (a.effectiveDriverName ?? 'zzzz').toLowerCase();
          final dB = (b.effectiveDriverName ?? 'zzzz').toLowerCase();
          final dCmp = dA.compareTo(dB);
          if (dCmp != 0) return dCmp;
          return a.name.compareTo(b.name);
      }
    });

    vm.updateAutoRefreshTargets(
      autoRefreshPool,
      filteredCount: filtered.length,
    );

    final isWide = MediaQuery.sizeOf(context).width >= 800;

    final activeStatusFilterCount =
        _selectedMotions.length +
        (_onlyOnCall ? 1 : 0) +
        (_onlyWithSnapshots ? 1 : 0) +
        (!_hidePoweredOff ? 1 : 0);

    final totalMobileFilterCount =
        activeOrgs.length +
        activeGroups.length +
        (_onlyOnCall ? 1 : 0) +
        (_onlyWithSnapshots ? 1 : 0) +
        (!_hidePoweredOff ? 1 : 0) +
        ((_selectedMotions.length != 2 ||
                !_selectedMotions.contains(VehicleMotionCategory.transit) ||
                !_selectedMotions.contains(VehicleMotionCategory.idle))
            ? 1
            : 0);

    final orgButtonLabel = activeOrgs.isEmpty
        ? 'Org: All (${sortedOrgs.length})'
        : (activeOrgs.length == 1
              ? 'Org: ${activeOrgs.first}'
              : 'Org: ${activeOrgs.length} selected');

    final groupButtonLabel = activeGroups.isEmpty
        ? 'Groups: All (${sortedGroups.length})'
        : (activeGroups.length <= 2
              ? 'Groups: ${activeGroups.join(", ")}'
              : 'Groups: ${activeGroups.length} selected');

    final filtersButtonLabel = activeStatusFilterCount == 0
        ? 'Filters'
        : 'Filters ($activeStatusFilterCount)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Toolbar: Single compact 1-line bar on Phone (<800px), Full toolbar on Desktop (>=800px)
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: isWide ? 14 : 10,
            vertical: isWide ? 10 : 7,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFF1E2127),
            border: Border(bottom: BorderSide(color: Color(0xFF33373F))),
          ),
          child: isWide
              ? Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 230,
                          child: TextField(
                            controller: _searchController,
                            onChanged: (v) =>
                                setState(() => _searchQuery = v.trim()),
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Search unit, driver, group, org...',
                              prefixIcon: const Icon(Icons.search, size: 17),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear, size: 15),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() => _searchQuery = '');
                                      },
                                    )
                                  : null,
                              isDense: true,
                              filled: true,
                              fillColor: const Color(0xFF14161A),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                  color: Color(0xFF33373F),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                  color: Color(0xFF33373F),
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Organization Selector Dialog Button
                        if (sortedOrgs.isNotEmpty)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: activeOrgs.isNotEmpty
                                  ? const Color(
                                      0xFF1E3A8A,
                                    ).withValues(alpha: 0.35)
                                  : const Color(0xFF14161A),
                              side: BorderSide(
                                color: activeOrgs.isNotEmpty
                                    ? const Color(0xFF3B82F6)
                                    : const Color(0xFF33373F),
                              ),
                            ),
                            onPressed: () => _showOrgFilterDialog(
                              context,
                              sortedOrgs,
                              orgCounts,
                            ),
                            icon: const Icon(Icons.business_outlined, size: 15),
                            label: Text(
                              orgButtonLabel,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),

                        // Multi-Group / Association Dialog Button
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: activeGroups.isNotEmpty
                                ? const Color(
                                    0xFF1E3A8A,
                                  ).withValues(alpha: 0.35)
                                : const Color(0xFF14161A),
                            side: BorderSide(
                              color: activeGroups.isNotEmpty
                                  ? const Color(0xFF3B82F6)
                                  : const Color(0xFF33373F),
                            ),
                          ),
                          onPressed: sortedGroups.isEmpty
                              ? null
                              : () => _showMultiGroupDialog(
                                  context,
                                  sortedGroups,
                                  groupCounts,
                                ),
                          icon: const Icon(Icons.workspaces_outlined, size: 15),
                          label: Text(
                            groupButtonLabel,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),

                        // Motion & Status Filters Dialog Button
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: activeStatusFilterCount > 0
                                ? const Color(
                                    0xFF1E3A8A,
                                  ).withValues(alpha: 0.35)
                                : const Color(0xFF14161A),
                            side: BorderSide(
                              color: activeStatusFilterCount > 0
                                  ? const Color(0xFF3B82F6)
                                  : const Color(0xFF33373F),
                            ),
                          ),
                          onPressed: () => _showStatusFiltersDialog(
                            context,
                            motionCounts,
                            onCallCount,
                            withSnapshotsCount,
                          ),
                          icon: const Icon(Icons.tune, size: 15),
                          label: Text(
                            filtersButtonLabel,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),

                        // Sort Selector
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 230),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF14161A),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFF33373F),
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<SafetySortOption>(
                                value: _sortOption,
                                isDense: true,
                                isExpanded: true,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFE8E8E8),
                                ),
                                dropdownColor: const Color(0xFF1E2127),
                                items: SafetySortOption.values
                                    .map(
                                      (opt) => DropdownMenuItem(
                                        value: opt,
                                        child: Text(
                                          opt.label,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _sortOption = val);
                                    _saveFilterPrefs();
                                  }
                                },
                              ),
                            ),
                          ),
                        ),

                        if (_hasNonDefaultFilters || focusedId != null)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: _resetFilters,
                            icon: const Icon(Icons.restart_alt, size: 15),
                            label: const Text(
                              'Reset',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // Auto-Refresh Cameras Interval Selector + Countdown Timer
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: vm.cameraAutoRefreshMinutes > 0
                                ? const Color(
                                    0xFF1E3A8A,
                                  ).withValues(alpha: 0.35)
                                : const Color(0xFF14161A),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: vm.cameraAutoRefreshMinutes > 0
                                  ? const Color(0xFF3B82F6)
                                  : const Color(0xFF33373F),
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: const {0, 5, 10, 15, 30}.contains(
                                    vm.cameraAutoRefreshMinutes,
                                  )
                                  ? vm.cameraAutoRefreshMinutes
                                  : 0,
                              isDense: true,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFE8E8E8),
                              ),
                              dropdownColor: const Color(0xFF1E2127),
                              items: const [
                                DropdownMenuItem(
                                  value: 0,
                                  child: Text('Auto-Refresh: Off'),
                                ),
                                DropdownMenuItem(
                                  value: 5,
                                  child: Text('Auto-Refresh: 5m'),
                                ),
                                DropdownMenuItem(
                                  value: 10,
                                  child: Text('Auto-Refresh: 10m'),
                                ),
                                DropdownMenuItem(
                                  value: 15,
                                  child: Text('Auto-Refresh: 15m'),
                                ),
                                DropdownMenuItem(
                                  value: 30,
                                  child: Text('Auto-Refresh: 30m'),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  vm.setCameraAutoRefreshMinutes(val);
                                }
                              },
                            ),
                          ),
                        ),
                        ValueListenableBuilder<int>(
                          valueListenable: vm.clockTickNotifier,
                          builder: (context, _, _) {
                            final countdown = vm.autoRefreshCountdownText;
                            if (countdown == null) {
                              return const SizedBox.shrink();
                            }
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF14161A),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: const Color(0xFF3B82F6),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.timer_outlined,
                                    size: 13,
                                    color: Color(0xFF93C5FD),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Next: $countdown',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF93C5FD),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: vm.isMotiveLoading
                              ? null
                              : vm.syncMotiveFleet,
                          icon: const Icon(Icons.sync, size: 15),
                          label: const Text(
                            'Sync Fleet',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        if (vm.isBatchRefreshingCameras)
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFE5484D),
                              foregroundColor: Colors.white,
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: vm.stopBatchCameraRefresh,
                            icon: const Icon(Icons.stop, size: 15),
                            label: const Text(
                              'Stop Batch',
                              style: TextStyle(fontSize: 12),
                            ),
                          )
                        else
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: filtered.isEmpty
                                ? null
                                : () =>
                                      vm.refreshBatchCameras(targets: filtered),
                            icon: const Icon(
                              Icons.cameraswitch_rounded,
                              size: 15,
                            ),
                            label: Text(
                              'Refresh Shown (${filtered.length})',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ],
                )
              : _buildMobileCompactToolbar(
                  context,
                  vm: vm,
                  filtered: filtered,
                  sortedOrgs: sortedOrgs,
                  orgCounts: orgCounts,
                  sortedGroups: sortedGroups,
                  groupCounts: groupCounts,
                  motionCounts: motionCounts,
                  onCallCount: onCallCount,
                  withSnapshotsCount: withSnapshotsCount,
                  totalMobileFilterCount: totalMobileFilterCount,
                ),
        ),

        // Vehicles Grid with True 16:9 Aspect Ratio Camera Cards
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        vm.authService.hasMotiveSession
                            ? 'No vehicles match the active filters.'
                            : 'Connect your Motive account in Connections to load the fleet.',
                        style: const TextStyle(color: Color(0xFF8B909C)),
                      ),
                      if (vm.authService.hasMotiveSession &&
                          _hasNonDefaultFilters) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _resetFilters,
                          icon: const Icon(Icons.restart_alt, size: 16),
                          label: const Text('Reset Filters'),
                        ),
                      ],
                    ],
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final int crossAxisCount;
                    if (constraints.maxWidth >= 1400) {
                      crossAxisCount = 3;
                    } else if (constraints.maxWidth >= 880) {
                      crossAxisCount = 2;
                    } else {
                      crossAxisCount = 1;
                    }

                    // Calculate exact card height so the main 16:9 Driver Cam and
                    // top 16:9 secondary thumbnail strip are never squished or cropped!
                    const double gridPad = 14.0;
                    const double spacing = 14.0;
                    final double totalHorizontalPad =
                        (gridPad * 2) + (spacing * (crossAxisCount - 1));
                    final double cardWidth =
                        ((constraints.maxWidth - totalHorizontalPad) /
                                crossAxisCount)
                            .clamp(280.0, 900.0);
                    final double innerCamWidth = (cardWidth - 20.0).clamp(
                      240.0,
                      880.0,
                    );
                    final double mainCamHeight = innerCamWidth * 9.0 / 16.0;
                    final double thumbStripHeight = (mainCamHeight * 0.38)
                        .clamp(78.0, 118.0);
                    // Header (~98) + thumbStrip + gap (6) + mainCamHeight + Footer (~52) + borders (12)
                    final double cardHeight =
                        98.0 +
                        thumbStripHeight +
                        6.0 +
                        mainCamHeight +
                        52.0 +
                        12.0;

                    return GridView.builder(
                      padding: const EdgeInsets.all(gridPad),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisExtent: cardHeight,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        return _buildVehicleCard(
                          context,
                          filtered,
                          index,
                          isFocused: filtered[index].id == focusedId,
                          thumbStripHeight: thumbStripHeight,
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildMobileCompactToolbar(
    BuildContext context, {
    required AppShellViewModel vm,
    required List<MotiveVehicle> filtered,
    required List<String> sortedOrgs,
    required Map<String, int> orgCounts,
    required List<String> sortedGroups,
    required Map<String, int> groupCounts,
    required Map<VehicleMotionCategory, int> motionCounts,
    required int onCallCount,
    required int withSnapshotsCount,
    required int totalMobileFilterCount,
  }) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 36,
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                constraints: const BoxConstraints.tightFor(height: 36),
                hintText: 'Search unit, driver...',
                hintStyle: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8B909C),
                ),
                prefixIcon: const Icon(Icons.search, size: 15),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 36,
                  maxHeight: 36,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF14161A),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF33373F)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFF33373F)),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        // Filters, Sort & Auto-Refresh Sheet Button
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            backgroundColor: totalMobileFilterCount > 0
                ? const Color(0xFF1E3A8A).withValues(alpha: 0.35)
                : const Color(0xFF14161A),
            side: BorderSide(
              color: totalMobileFilterCount > 0
                  ? const Color(0xFF3B82F6)
                  : const Color(0xFF33373F),
            ),
          ),
          onPressed: () => _showMobileFilterAndSortSheet(
            context,
            vm: vm,
            sortedOrgs: sortedOrgs,
            orgCounts: orgCounts,
            sortedGroups: sortedGroups,
            groupCounts: groupCounts,
            motionCounts: motionCounts,
            onCallCount: onCallCount,
            withSnapshotsCount: withSnapshotsCount,
          ),
          icon: const Icon(Icons.tune_rounded, size: 14),
          label: Text(
            totalMobileFilterCount > 0
                ? 'Filter ($totalMobileFilterCount)'
                : 'Filter',
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
        const SizedBox(width: 6),
        // Auto-Refresh Countdown Pill (tappable to configure interval)
        ValueListenableBuilder<int>(
          valueListenable: vm.clockTickNotifier,
          builder: (context, _, _) {
            final countdown = vm.autoRefreshCountdownText;
            if (countdown == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                onTap: () => _showMobileFilterAndSortSheet(
                  context,
                  vm: vm,
                  sortedOrgs: sortedOrgs,
                  orgCounts: orgCounts,
                  sortedGroups: sortedGroups,
                  groupCounts: groupCounts,
                  motionCounts: motionCounts,
                  onCallCount: onCallCount,
                  withSnapshotsCount: withSnapshotsCount,
                ),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF14161A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF3B82F6)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.timer_outlined,
                        size: 12,
                        color: Color(0xFF93C5FD),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        countdown,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF93C5FD),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        // Batch Refresh / Stop Button
        if (vm.isBatchRefreshingCameras)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            onPressed: vm.stopBatchCameraRefresh,
            icon: const Icon(Icons.stop, size: 14),
            label: const Text('Stop', style: TextStyle(fontSize: 11.5)),
          )
        else
          FilledButton.icon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            onPressed: filtered.isEmpty
                ? null
                : () => vm.refreshBatchCameras(targets: filtered),
            icon: const Icon(Icons.cameraswitch_rounded, size: 14),
            label: Text(
              'Refresh (${filtered.length})',
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        const SizedBox(width: 4),
        IconButton.outlined(
          visualDensity: VisualDensity.compact,
          tooltip: 'Sync Fleet',
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xFF14161A),
            side: const BorderSide(color: Color(0xFF33373F)),
          ),
          onPressed: vm.isMotiveLoading ? null : vm.syncMotiveFleet,
          icon: vm.isMotiveLoading
              ? const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync, size: 15),
        ),
      ],
    );
  }

  void _showMobileFilterAndSortSheet(
    BuildContext context, {
    required AppShellViewModel vm,
    required List<String> sortedOrgs,
    required Map<String, int> orgCounts,
    required List<String> sortedGroups,
    required Map<String, int> groupCounts,
    required Map<VehicleMotionCategory, int> motionCounts,
    required int onCallCount,
    required int withSnapshotsCount,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E2127),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.82,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text(
                              'Camera Filters, Sort & Auto-Refresh',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFE8E8E8),
                              ),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: () {
                                  _resetFilters();
                                  setModalState(() {});
                                },
                                child: const Text('Reset All'),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: () => Navigator.of(ctx).pop(),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xFF33373F), height: 12),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 1. Auto-Refresh Interval
                              const Text(
                                'AUTO-REFRESH CAMERAS',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF8B909C),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [0, 5, 10, 15, 30].map((mins) {
                                  final selected =
                                      vm.cameraAutoRefreshMinutes == mins;
                                  final label = mins == 0
                                      ? 'Off'
                                      : 'Every ${mins}m';
                                  return ChoiceChip(
                                    label: Text(
                                      label,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    selected: selected,
                                    onSelected: (_) {
                                      vm.setCameraAutoRefreshMinutes(mins);
                                      setModalState(() {});
                                    },
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 14),

                              // 2. Sort Order
                              const Text(
                                'SORT BY',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF8B909C),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF14161A),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFF33373F),
                                  ),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<SafetySortOption>(
                                    value: _sortOption,
                                    isExpanded: true,
                                    dropdownColor: const Color(0xFF1E2127),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFFE8E8E8),
                                    ),
                                    items: SafetySortOption.values
                                        .map(
                                          (opt) => DropdownMenuItem(
                                            value: opt,
                                            child: Text(opt.label),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setState(() => _sortOption = val);
                                        _saveFilterPrefs();
                                        setModalState(() {});
                                      }
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),

                              // 3. Vehicle Motion Filter
                              const Text(
                                'VEHICLE MOTION',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF8B909C),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: VehicleMotionCategory.values.map((m) {
                                  final checked = _selectedMotions.contains(m);
                                  final count = motionCounts[m] ?? 0;
                                  return FilterChip(
                                    label: Text(
                                      '${m.label} ($count)',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    selected: checked,
                                    onSelected: (val) {
                                      setState(() {
                                        if (val) {
                                          _selectedMotions.add(m);
                                        } else {
                                          _selectedMotions.remove(m);
                                        }
                                      });
                                      _saveFilterPrefs();
                                      setModalState(() {});
                                    },
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 14),

                              // 4. Organization Filter
                              if (sortedOrgs.isNotEmpty) ...[
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'ORGANIZATIONS',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF8B909C),
                                      ),
                                    ),
                                    if (_selectedOrgs.isNotEmpty)
                                      TextButton(
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: () {
                                          setState(() => _selectedOrgs.clear());
                                          _saveFilterPrefs();
                                          setModalState(() {});
                                        },
                                        child: const Text(
                                          'All Orgs',
                                          style: TextStyle(fontSize: 11.5),
                                        ),
                                      ),
                                  ],
                                ),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: sortedOrgs.map((org) {
                                    final checked = _selectedOrgs.contains(org);
                                    final count = orgCounts[org] ?? 0;
                                    return FilterChip(
                                      label: Text(
                                        '$org ($count)',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      selected: checked,
                                      onSelected: (val) {
                                        setState(() {
                                          if (val) {
                                            _selectedOrgs.add(org);
                                          } else {
                                            _selectedOrgs.remove(org);
                                          }
                                        });
                                        _saveFilterPrefs();
                                        setModalState(() {});
                                      },
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 14),
                              ],

                              // 5. Fleet Groups / Associations
                              if (sortedGroups.isNotEmpty) ...[
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'FLEET GROUPS / ASSOCIATIONS',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF8B909C),
                                      ),
                                    ),
                                    if (_selectedGroups.isNotEmpty)
                                      TextButton(
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        onPressed: () {
                                          setState(
                                            () => _selectedGroups.clear(),
                                          );
                                          _saveFilterPrefs();
                                          setModalState(() {});
                                        },
                                        child: const Text(
                                          'All Groups',
                                          style: TextStyle(fontSize: 11.5),
                                        ),
                                      ),
                                  ],
                                ),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: sortedGroups.map((grp) {
                                    final checked = _selectedGroups.contains(
                                      grp,
                                    );
                                    final count = groupCounts[grp] ?? 0;
                                    return FilterChip(
                                      label: Text(
                                        '$grp ($count)',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      selected: checked,
                                      onSelected: (val) {
                                        setState(() {
                                          if (val) {
                                            _selectedGroups.add(grp);
                                          } else {
                                            _selectedGroups.remove(grp);
                                          }
                                        });
                                        _saveFilterPrefs();
                                        setModalState(() {});
                                      },
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 10),
                              ],

                              // 6. Status & Snapshot Switches
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                value: _onlyOnCall,
                                title: Text(
                                  'On Call Only ($onCallCount)',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                onChanged: (val) {
                                  setState(() => _onlyOnCall = val);
                                  _saveFilterPrefs();
                                  setModalState(() {});
                                },
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                value: _onlyWithSnapshots,
                                title: Text(
                                  'Captured Snapshots Only ($withSnapshotsCount)',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                onChanged: (val) {
                                  setState(() => _onlyWithSnapshots = val);
                                  _saveFilterPrefs();
                                  setModalState(() {});
                                },
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                value: _hidePoweredOff,
                                title: const Text(
                                  'Hide Powered Off Vehicles',
                                  style: TextStyle(fontSize: 13),
                                ),
                                onChanged: (val) {
                                  setState(() => _hidePoweredOff = val);
                                  _saveFilterPrefs();
                                  setModalState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Apply & Close'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildVehicleCard(
    BuildContext context,
    List<MotiveVehicle> list,
    int index, {
    required bool isFocused,
    required double thumbStripHeight,
  }) {
    final v = list[index];
    final link = v.linkedFslDriver;
    final driverName = v.effectiveDriverName;
    final ageLabel = v.shortAgeLabel();
    final mainEntry = v.mainCameraEntry;
    final thumbEntries = v.thumbnailCameraEntries;
    final isReporting = _reportingVehicleIds.contains(v.id);

    // Secondary camera preview: show captured secondary thumbs, or a 16:9 placeholder for Road Cam
    final hasSecondaryThumbs = thumbEntries.isNotEmpty;

    return Card(
      color: const Color(0xFF1E2127),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isFocused ? const Color(0xFFF5A623) : const Color(0xFF33373F),
          width: isFocused ? 2.0 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            v.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: Color(0xFFE8E8E8),
                            ),
                          ),
                          _buildPill(
                            v.organizationName,
                            const Color(0xFF3B82F6),
                          ),
                          if (v.associationGroup.isNotEmpty &&
                              v.associationGroup.toUpperCase() !=
                                  v.organizationName.toUpperCase())
                            _buildPill(
                              v.associationGroup,
                              const Color(0xFF0EA5E9),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        driverName != null
                            ? 'Driver: $driverName${link != null ? " • On Call (${link.signal.badgeText})" : ""}'
                            : 'No Associated Driver',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: driverName != null
                              ? const Color(0xFFCBD5E1)
                              : const Color(0xFF8B909C),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                _buildPill(
                  v.isPoweredOff ? 'Powered Off' : v.statusText,
                  v.isPoweredOff
                      ? const Color(0xFFE5484D)
                      : (v.motionCategory == VehicleMotionCategory.transit
                            ? const Color(0xFF46A758)
                            : const Color(0xFFF5A623)),
                ),
              ],
            ),
          ),

          // Stitched Camera Stage with True 16:9 Aspect Ratios (Never Cropped or Squished):
          // - Top strip: 16:9 secondary thumbnails (Road Cam, etc.)
          // - Bottom hero: 16:9 Driver Cam
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: thumbStripHeight,
                    child: hasSecondaryThumbs
                        ? SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (
                                  int i = 0;
                                  i < thumbEntries.length;
                                  i++
                                ) ...[
                                  if (i > 0) const SizedBox(width: 6),
                                  AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: _buildCameraBox(
                                      label: thumbEntries[i].label,
                                      filePath: thumbEntries[i].path,
                                      revisionToken: v.lastRefreshedEpochMs,
                                      ageMark: ageLabel,
                                      isThumbnail: true,
                                      onTap: () => _openLightbox(
                                        context,
                                        list,
                                        index,
                                        initialAngleKey: 'stitched',
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : AspectRatio(
                            aspectRatio: 16 / 9,
                            child: _buildCameraBox(
                              label: 'Road Cam',
                              filePath: v.roadCameraPath,
                              revisionToken: v.lastRefreshedEpochMs,
                              ageMark: ageLabel,
                              fallbackStatusText: 'Road Cam',
                              isThumbnail: true,
                              onTap: () => _openLightbox(
                                context,
                                list,
                                index,
                                initialAngleKey: 'stitched',
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: _buildCameraBox(
                          label: mainEntry?.label ?? 'Driver Cam',
                          filePath: mainEntry?.path,
                          revisionToken: v.lastRefreshedEpochMs,
                          ageMark: ageLabel,
                          fallbackStatusText: v.cameraStatusText,
                          isThumbnail: false,
                          onTap: () => _openLightbox(
                            context,
                            list,
                            index,
                            initialAngleKey: 'stitched',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom Action Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF46A758),
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: isReporting
                      ? null
                      : () => _handleSingleButtonReport(context, v),
                  icon: isReporting
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 14),
                  label: const Text(
                    'Report',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () =>
                              widget.viewModel.refreshSingleCamera(v.id),
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text(
                            'Refresh',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: const EdgeInsets.all(4),
                        tooltip: 'Inspect Fullscreen (← / →)',
                        onPressed: () => _openLightbox(
                          context,
                          list,
                          index,
                          initialAngleKey: 'stitched',
                        ),
                        icon: const Icon(Icons.fullscreen, size: 18),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: const EdgeInsets.all(4),
                        tooltip: 'Open Live View in Motive',
                        onPressed: () => _openInMotiveWeb(v),
                        icon: const Icon(Icons.open_in_new, size: 15),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openLightbox(
    BuildContext context,
    List<MotiveVehicle> list,
    int index, {
    String initialAngleKey = 'stitched',
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => CameraLightboxDialog(
        vehicles: list,
        initialIndex: index,
        onRefreshCamera: widget.viewModel.refreshSingleCamera,
        resolveLatestVehicle: widget.viewModel.findVehicleById,
        initialAngleKey: initialAngleKey,
      ),
    );
  }

  Widget _buildCameraBox({
    required String label,
    required String? filePath,
    required int? revisionToken,
    required String ageMark,
    required bool isThumbnail,
    required VoidCallback onTap,
    String? fallbackStatusText,
  }) {
    final hasFile = filePath != null && filePath.isNotEmpty;
    return RepaintBoundary(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0A0C0E),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF33373F)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasFile)
                Image.file(
                  File(filePath),
                  key: ValueKey('$filePath-${revisionToken ?? 0}'),
                  cacheWidth: isThumbnail ? 320 : 720,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  // BoxFit.contain inside a 16:9 AspectRatio container ensures 0% cropping/squishing!
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Center(
                    child: Icon(
                      Icons.videocam_off_outlined,
                      size: isThumbnail ? 16 : 22,
                      color: const Color(0xFF8B909C),
                    ),
                  ),
                )
              else
                Center(
                  child: isThumbnail
                      ? const Icon(
                          Icons.videocam_off_outlined,
                          size: 16,
                          color: Color(0xFF8B909C),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.videocam_off_outlined,
                              size: 22,
                              color: Color(0xFF8B909C),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              fallbackStatusText ?? label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF8B909C),
                              ),
                            ),
                          ],
                        ),
                ),
            // Corner mark for when it was last updated (Now, 2m, 5m, etc.)
            if (ageMark.isNotEmpty && hasFile)
              Positioned(
                top: isThumbnail ? 4 : 6,
                right: isThumbnail ? 4 : 6,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isThumbnail ? 5 : 7,
                    vertical: isThumbnail ? 1.5 : 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xD914161A),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF46A758)),
                  ),
                  child: Text(
                    ageMark,
                    style: TextStyle(
                      fontSize: isThumbnail ? 9.0 : 10.5,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF46A758),
                    ),
                  ),
                ),
              ),
            // Angle label in bottom-left corner
            Positioned(
              bottom: isThumbnail ? 4 : 6,
              left: isThumbnail ? 4 : 6,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isThumbnail ? 5 : 7,
                  vertical: isThumbnail ? 1.5 : 2.5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xD914161A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF33373F)),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: isThumbnail ? 9.0 : 10.0,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFE8E8E8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildPill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
