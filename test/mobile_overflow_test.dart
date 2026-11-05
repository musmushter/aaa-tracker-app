import 'package:aaa_tracker_app/data/models/fsl_api_models.dart';
import 'package:aaa_tracker_app/data/models/motive_api_models.dart';
import 'package:aaa_tracker_app/data/repositories/fsl_repository.dart';
import 'package:aaa_tracker_app/data/repositories/motive_repository.dart';
import 'package:aaa_tracker_app/data/services/auth_session_service.dart';
import 'package:aaa_tracker_app/data/services/fsl_api_client.dart';
import 'package:aaa_tracker_app/data/services/motive_api_client.dart';
import 'package:aaa_tracker_app/data/services/snapshot_storage_service.dart';
import 'package:aaa_tracker_app/domain/models/motive_vehicle.dart';
import 'package:aaa_tracker_app/domain/use_cases/fsl_time_utils.dart';
import 'package:aaa_tracker_app/ui/core/app_theme.dart';
import 'package:aaa_tracker_app/ui/features/auth/views/auth_settings_dialog.dart';
import 'package:aaa_tracker_app/ui/features/safety/views/camera_lightbox_dialog.dart';
import 'package:aaa_tracker_app/ui/features/shell/view_models/app_shell_view_model.dart';
import 'package:aaa_tracker_app/ui/features/shell/views/app_shell_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoOpSnapshotStorage extends SnapshotStorageService {
  @override
  Future<int> pruneExpiredSnapshots() async => 0;
}

class _FakeMotiveApiClient extends MotiveApiClient {
  _FakeMotiveApiClient(this.mockVehicles) : super(snapshotStorage: _NoOpSnapshotStorage());
  final List<MotiveVehicle> mockVehicles;

  @override
  Future<List<MotiveVehicle>> fetchVehiclesForAccount(MotiveAccountSession account) async {
    return mockVehicles.where((v) => v.organizationId == account.organizationId).toList();
  }
}

void main() {
  setUpAll(() {
    FslTimeUtils.ensureInitialized();
  });

  testWidgets('Render all tabs and dialogs at 360x780 Android phone viewport', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0; // 360x780 logical pixels
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var currentPhase = 'init';
    final errors = <String>[];
    final origOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add('[$currentPhase] ${details.exceptionAsString()}\n${details.toString()}');
    };

    final auth = AuthSessionService();
    await auth.saveFslSession(cookieHeader: 'sid=test');
    await auth.upsertMotiveAccount(const MotiveAccountSession(
      organizationId: '260129',
      organizationName: 'HEART',
      authToken: 'tok1',
    ));
    await auth.upsertMotiveAccount(const MotiveAccountSession(
      organizationId: '599530',
      organizationName: 'Houston Towing',
      authToken: 'tok2',
    ));

    const nowMs = 1760940000000;
    final dummyVehicles = <MotiveVehicle>[
      MotiveVehicle(
        id: '101',
        name: 'Jessica Miranda (71) -P690',
        organizationId: '260129',
        organizationName: 'HEART',
        associationGroup: 'HOUSTON EMERGENCY AUTO RESCUE',
        assignedDriverName: 'Jessica Miranda',
        makeModelYear: 'Ford F-550',
        statusText: 'In Transit (45.2 mph)',
        motionCategory: VehicleMotionCategory.transit,
        speedMph: 45.2,
        hasCamera: true,
        isPoweredOff: false,
        lastRefreshedEpochMs: nowMs - 60000,
      ),
      MotiveVehicle(
        id: '102',
        name: 'Thaer Zakarneh -P734',
        organizationId: '599530',
        organizationName: 'Houston Towing',
        associationGroup: 'HOUSTON TOWING',
        assignedDriverName: 'Thaer Zakarneh',
        makeModelYear: 'Ford F-550',
        statusText: 'Idling',
        motionCategory: VehicleMotionCategory.idle,
        speedMph: 0,
        hasCamera: true,
        isPoweredOff: false,
      ),
    ];

    final snap = _NoOpSnapshotStorage();
    final fslRepo = FslRepository(apiClient: FslApiClient(authService: auth));
    final motiveRepo = MotiveRepository(
      apiClient: _FakeMotiveApiClient(dummyVehicles),
      authService: auth,
      snapshotStorage: snap,
    );

    fslRepo.ingestAppointmentsAndResources(
      appointments: [
        FslServiceAppointmentDto.fromJson({
          'Id': '08pActive1',
          'Resource': '0HnDrv1',
          'ResourceName': 'Jessica Miranda (71)**818 210 8302**713 478 8925',
          'Fields': {
            'Id': '08pActive1',
            'AppointmentNumber': 'SA-84746601',
            'D3_Call_ID__c': '573952',
            'Status': 'En Route',
            'WorkType': 'Flatbed Tow',
            'ServiceTerritory.Name': '631252 - HOUSTON EMERGENCY AUTO RESCUE',
            'GanttColor__c': '#FF1E1E',
            'FSL_Member_Vehicle_Name__c': '2022 Ford F-150 SuperCrew',
            'Street': '12345 Westheimer Rd',
            'City': 'Houston',
            'SchedStartTime': FslTimeUtils.epochMsToSfWallClockMs(nowMs - 40 * 60000),
            'LastModifiedDate': nowMs - 20 * 60000,
          },
        }),
        FslServiceAppointmentDto.fromJson({
          'Id': '08pCleared1',
          'Resource': '0HnDrv2',
          'ResourceName': 'Omar Hassan (21)**713 555 0106',
          'Fields': {
            'Id': '08pCleared1',
            'AppointmentNumber': 'SA-84745000',
            'D3_Call_ID__c': '570001',
            'Status': 'Cleared',
            'WorkType': 'Battery Service',
            'ServiceTerritory.Name': '631252 - HOUSTON EMERGENCY AUTO RESCUE',
            'Phone_Number__c': '(832) 555-0199',
            'Member_Benefit_Level__c': 'Premier RV',
            'FSL_Member_Vehicle_Name__c': '2021 Chevrolet Tahoe Black',
            'SchedStartTime': FslTimeUtils.epochMsToSfWallClockMs(nowMs - 50 * 60000),
            'ActualStartTime': FslTimeUtils.epochMsToSfWallClockMs(nowMs - 20 * 60000),
            'LastModifiedDate': nowMs - 5 * 60000,
          },
        }),
      ],
      resources: const [],
      nowEpochMs: nowMs,
    );
    fslRepo.evaluateCurrentState(nowEpochMs: nowMs);

    final vm = AppShellViewModel(
      authService: auth,
      fslRepository: fslRepo,
      motiveRepository: motiveRepo,
    );
    await vm.syncMotiveFleet();

    currentPhase = 'Tab0_Dispatch';
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: AppShellView(viewModel: vm),
    ));
    await tester.pumpAndSettle();

    currentPhase = 'Tab1_Callbacks';
    vm.selectTab(1);
    await tester.pumpAndSettle();

    currentPhase = 'Tab2_SafetyCams';
    vm.selectTab(2);
    await tester.pumpAndSettle();

    currentPhase = 'Dialog_Groups';
    await tester.tap(find.textContaining('Groups:'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    currentPhase = 'Dialog_Orgs';
    await tester.tap(find.textContaining('Org:'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    currentPhase = 'Dialog_StatusFilters';
    await tester.tap(find.textContaining('Filters'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    currentPhase = 'Dialog_AuthSettings';
    showDialog<void>(
      context: tester.element(find.byType(AppShellView)),
      builder: (_) => AuthSettingsDialog(viewModel: vm),
    );
    await tester.pumpAndSettle();
    // Expand ExpansionTile in AuthSettingsDialog
    await tester.ensureVisible(find.textContaining('Advanced:'));
    await tester.tap(find.textContaining('Advanced:'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AuthSettingsDialog))).pop();
    await tester.pumpAndSettle();

    currentPhase = 'Dialog_CameraLightbox';
    showDialog<void>(
      context: tester.element(find.byType(AppShellView)),
      builder: (_) => CameraLightboxDialog(
        vehicles: dummyVehicles,
        initialIndex: 0,
        onRefreshCamera: (_) async => null,
        autoRefreshIfMissing: false,
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(CameraLightboxDialog))).pop();
    await tester.pumpAndSettle();

    vm.dispose();
    FlutterError.onError = origOnError;

    expect(errors, isEmpty);
    if (errors.isNotEmpty) {
      // ignore: avoid_print
      expect(errors, isEmpty);
    }
  });
}
