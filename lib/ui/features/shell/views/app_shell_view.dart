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

        return Scaffold(
          backgroundColor: const Color(0xFF14161A),
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF1E2127),
                border: Border(
                  bottom: BorderSide(color: Color(0xFF33373F)),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'AAA Dispatch & Safety',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFE8E8E8),
                    ),
                  ),
                  if (isWide) ...[
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
                      badgeCount: viewModel.clearedCalls.length,
                      selected: viewModel.selectedTabIndex == 1,
                      onTap: () => viewModel.selectTab(1),
                    ),
                    const SizedBox(width: 6),
                    _NavTabButton(
                      label: 'Safety Cameras',
                      badgeCount: viewModel.motiveVehicles.length,
                      selected: viewModel.selectedTabIndex == 2,
                      onTap: () => viewModel.selectTab(2),
                    ),
                  ],
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      viewModel.statusBannerText,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8B909C),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
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
                      'Connections (FSL${motiveCount > 0 ? " + $motiveCount Orgs" : ""})',
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
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: viewModel.clearedCalls.isNotEmpty,
                        label: Text('${viewModel.clearedCalls.length}'),
                        child: const Icon(Icons.phone_callback_rounded),
                      ),
                      label: 'Callbacks',
                    ),
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: viewModel.motiveVehicles.isNotEmpty,
                        label: Text('${viewModel.motiveVehicles.length}'),
                        child: const Icon(Icons.videocam_rounded),
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
