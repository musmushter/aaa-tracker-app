import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../auth/views/auth_settings_dialog.dart';
import '../../dispatch/views/callback_log_view.dart';
import '../../dispatch/views/dispatch_dashboard_view.dart';
import '../../safety/views/safety_console_view.dart';
import '../view_models/app_shell_view_model.dart';

/// Adaptive cross-platform application shell.
///
/// Uses an [IndexedStack] so switching tabs never resets filter or scroll state,
/// a compact top navigation bar on Desktop/Tablet (`>= 800px`), and a bottom
/// [NavigationBar] on Android phones.
class AppShellView extends StatelessWidget {
  const AppShellView({super.key, required this.viewModel});

  final AppShellViewModel viewModel;

  void _openAuthDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AuthSettingsDialog(viewModel: viewModel),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final isWide = MediaQuery.sizeOf(context).width >= 800;
        final pages = <Widget>[
          DispatchDashboardView(viewModel: viewModel),
          CallbackLogView(viewModel: viewModel),
          SafetyConsoleView(viewModel: viewModel),
        ];

        final fslConnected = viewModel.authService.hasFslSession;
        final motiveCount = viewModel.authService.motiveAccounts.length;
        final topPad = MediaQuery.paddingOf(context).top;

        return Scaffold(
          backgroundColor: const Color(0xFF14161A),
          appBar: PreferredSize(
            preferredSize: Size.fromHeight(48 + topPad),
            child: Container(
              height: 48 + topPad,
              padding: EdgeInsets.only(top: topPad, left: 12, right: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF1E2127),
                border: Border(
                  bottom: BorderSide(color: Color(0xFF33373F)),
                ),
              ),
              child: Row(
                children: [
                  if (!isWide) ...[
                    const Expanded(
                      child: Text(
                        'AAA Tracker',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFE8E8E8),
                        ),
                      ),
                    ),
                    if (viewModel.dispatchAlerts.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5484D),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '⚠ ${viewModel.dispatchAlerts.length}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ] else ...[
                    const Text(
                      'AAA Dispatch & Safety',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFE8E8E8),
                      ),
                    ),
                    const SizedBox(width: 20),
                    _NavTabButton(
                      label: 'Dispatch Tracker',
                      badgeCount: viewModel.dispatchRows.length,
                      alertCount: viewModel.dispatchAlerts.length,
                      selected: viewModel.selectedTabIndex == 0,
                      onTap: () => viewModel.selectTab(0),
                    ),
                    const SizedBox(width: 6),
                    _NavTabButton(
                      label: 'Callbacks (12h)',
                      badgeCount: 0,
                      selected: viewModel.selectedTabIndex == 1,
                      onTap: () => viewModel.selectTab(1),
                    ),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<int>(
                      valueListenable: viewModel.filteredCameraCountNotifier,
                      builder: (context, filteredCamCount, _) {
                        return _NavTabButton(
                          label: 'Safety Cameras',
                          badgeCount: filteredCamCount,
                          selected: viewModel.selectedTabIndex == 2,
                          onTap: () => viewModel.selectTab(2),
                        );
                      },
                    ),
                  ],
                  const SizedBox(width: 6),
                  // Account-Synced Clock Pill (US Central / Account Location)
                  ValueListenableBuilder<int>(
                    valueListenable: viewModel.clockTickNotifier,
                    builder: (context, _, _) {
                      final clockStr = isWide
                          ? viewModel.accountClockText
                          : viewModel.accountClockText.replaceFirst(
                              'Central ',
                              '',
                            );
                      return Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: isWide ? 8 : 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF14161A),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF33373F)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.schedule_rounded,
                              size: 11,
                              color: Color(0xFF93C5FD),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              clockStr,
                              style: TextStyle(
                                fontSize: isWide ? 11.5 : 10.5,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFFE8E8E8),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  if (isWide) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        viewModel.statusBannerText,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF8B909C),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  // Alert Notifications & Background Keep-Alive Menu Button
                  PopupMenuButton<String>(
                    tooltip: 'Alerts & Persistent Notification Settings',
                    color: const Color(0xFF1E2127),
                    constraints: const BoxConstraints(
                      minWidth: 240,
                      maxWidth: 320,
                    ),
                    onSelected: (value) {
                      if (value == 'toggle_enabled') {
                        viewModel.setAlertsNotificationsEnabled(
                          !viewModel.alertsNotificationsEnabled,
                        );
                      } else if (value == 'toggle_sound') {
                        viewModel.setAlertsSoundEnabled(
                          !viewModel.alertsSoundEnabled,
                        );
                      } else if (value == 'toggle_keep_alive') {
                        viewModel.setAndroidKeepAliveEnabled(
                          !viewModel.androidKeepAliveEnabled,
                        );
                      } else if (value == 'toggle_summary_callbacks') {
                        viewModel.setShowCallbacksInSummary(
                          !viewModel.showCallbacksInSummary,
                        );
                      } else if (value == 'toggle_summary_cam_age') {
                        viewModel.setShowCameraAgeInSummary(
                          !viewModel.showCameraAgeInSummary,
                        );
                      } else if (value == 'unrestricted_battery') {
                        viewModel.requestUnrestrictedAndroidBattery();
                      } else if (value == 'test') {
                        viewModel.sendTestAlertNotification();
                      }
                    },
                    itemBuilder: (context) => [
                      CheckedPopupMenuItem<String>(
                        value: 'toggle_enabled',
                        checked: viewModel.alertsNotificationsEnabled,
                        child: const Text(
                          'Enable Alert Notifications',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      CheckedPopupMenuItem<String>(
                        value: 'toggle_sound',
                        checked: viewModel.alertsSoundEnabled,
                        child: const Text(
                          'Play Alert Sound',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem<String>(
                        value: 'toggle_keep_alive',
                        checked: viewModel.androidKeepAliveEnabled,
                        child: const Text(
                          'Persistent Live Notification & Keep-Alive',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      CheckedPopupMenuItem<String>(
                        value: 'toggle_summary_cam_age',
                        checked: viewModel.showCameraAgeInSummary,
                        child: Text(
                          'Show Camera Update Age (${viewModel.cameraLastUpdateAgeText})',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      CheckedPopupMenuItem<String>(
                        value: 'toggle_summary_callbacks',
                        checked: viewModel.showCallbacksInSummary,
                        child: const Text(
                          'Show Unchecked Callbacks Count',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android) ...[
                        PopupMenuItem<String>(
                          value: 'unrestricted_battery',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                viewModel.batteryOptimizationIgnored
                                    ? Icons.battery_charging_full_rounded
                                    : Icons.battery_saver_rounded,
                                size: 16,
                                color: viewModel.batteryOptimizationIgnored
                                    ? const Color(0xFF46A758)
                                    : const Color(0xFFF5A623),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  viewModel.batteryOptimizationIgnored
                                      ? 'Unrestricted Battery: Active'
                                      : 'Allow Unrestricted Battery (No Sleep)',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: 'test',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.notifications_active_outlined,
                              size: 16,
                              color: Color(0xFF93C5FD),
                            ),
                            SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                'Send Test Notification',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF14161A),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: viewModel.alertsNotificationsEnabled
                              ? const Color(0xFF46A758).withValues(alpha: 0.7)
                              : const Color(0xFF33373F),
                        ),
                      ),
                      child: Icon(
                        viewModel.alertsNotificationsEnabled
                            ? Icons.notifications_active_rounded
                            : Icons.notifications_off_outlined,
                        size: 15,
                        color: viewModel.alertsNotificationsEnabled
                            ? const Color(0xFF86EFAC)
                            : const Color(0xFF8B909C),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.symmetric(
                        horizontal: isWide ? 12 : 8,
                        vertical: 4,
                      ),
                      side: BorderSide(
                        color: (fslConnected && motiveCount > 0)
                            ? const Color(0xFF46A758)
                            : const Color(0xFFF5A623),
                      ),
                      foregroundColor: const Color(0xFFE8E8E8),
                    ),
                    onPressed: () => _openAuthDialog(context),
                    icon: Icon(
                      Icons.vpn_key_rounded,
                      size: 14,
                      color: (fslConnected && motiveCount > 0)
                          ? const Color(0xFF46A758)
                          : const Color(0xFFF5A623),
                    ),
                    label: Text(
                      isWide
                          ? 'Connections (FSL${motiveCount > 0 ? " + $motiveCount Orgs" : ""})'
                          : 'FSL${motiveCount > 0 ? "+$motiveCount" : ""}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // IndexedStack keeps all tab views alive so camera filters and scroll states never reset!
          body: IndexedStack(
            index: viewModel.selectedTabIndex,
            children: pages,
          ),
          bottomNavigationBar: isWide
              ? null
              : NavigationBar(
                  height: 58,
                  backgroundColor: const Color(0xFF1E2127),
                  selectedIndex: viewModel.selectedTabIndex,
                  onDestinationSelected: viewModel.selectTab,
                  destinations: [
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: viewModel.dispatchAlerts.isNotEmpty,
                        label: Text('${viewModel.dispatchAlerts.length}'),
                        child: const Icon(Icons.radar_rounded),
                      ),
                      label: 'Dispatch',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.phone_callback_rounded),
                      label: 'Callbacks',
                    ),
                    NavigationDestination(
                      icon: ValueListenableBuilder<int>(
                        valueListenable: viewModel.filteredCameraCountNotifier,
                        builder: (context, filteredCamCount, _) {
                          return Badge(
                            isLabelVisible: filteredCamCount > 0,
                            label: Text('$filteredCamCount'),
                            child: const Icon(Icons.videocam_rounded),
                          );
                        },
                      ),
                      label: 'Safety Cams',
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _NavTabButton extends StatelessWidget {
  const _NavTabButton({
    required this.label,
    required this.badgeCount,
    required this.selected,
    required this.onTap,
    this.alertCount = 0,
  });

  final String label;
  final int badgeCount;
  final int alertCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2B303B) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? const Color(0xFF4C5364) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? const Color(0xFFE8E8E8)
                    : const Color(0xFF8B909C),
              ),
            ),
            if (badgeCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF14161A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF33373F)),
                ),
                child: Text(
                  '$badgeCount',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE8E8E8),
                  ),
                ),
              ),
            ],
            if (alertCount > 0) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5484D),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$alertCount!',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
