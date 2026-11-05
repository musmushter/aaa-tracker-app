import 'package:aaa_tracker_app/data/models/fsl_api_models.dart';
import 'package:aaa_tracker_app/data/models/motive_api_models.dart';
import 'package:aaa_tracker_app/data/repositories/fsl_repository.dart';
import 'package:aaa_tracker_app/data/services/alert_notification_service.dart';
import 'package:aaa_tracker_app/data/services/auth_session_service.dart';
import 'package:aaa_tracker_app/data/services/fsl_api_client.dart';
import 'package:aaa_tracker_app/domain/models/dispatch_alert.dart';
import 'package:aaa_tracker_app/domain/models/dispatch_row.dart';
import 'package:aaa_tracker_app/domain/models/driver_truck_link.dart';
import 'package:aaa_tracker_app/domain/models/motive_vehicle.dart';
import 'package:aaa_tracker_app/domain/use_cases/dispatch_report_builder.dart';
import 'package:aaa_tracker_app/domain/use_cases/driver_truck_linker.dart';
import 'package:aaa_tracker_app/domain/use_cases/fsl_chatter_parser.dart';
import 'package:aaa_tracker_app/domain/use_cases/fsl_time_utils.dart';
import 'package:aaa_tracker_app/domain/use_cases/motive_report_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    FslTimeUtils.ensureInitialized();
  });

  group('FslTimeUtils & Driver Name Parsing for Reports', () {
    test('extracts unique 10-digit US phones and cleans real FSL & Motive driver names', () {
      const raw = 'Jordan Miles (71)**713 555 0101**832 555 0102 (100001)';
      final phones = FslTimeUtils.extractPhones(raw);
      expect(phones, equals(['(713) 555-0101', '(832) 555-0102']));

      expect(FslTimeUtils.cleanDriverName(raw), equals('Jordan Miles'));
      expect(
        FslTimeUtils.cleanDriverName(
          '100002 - Rafael(37) **832-555-0103** **346-555-0104**(100003)',
        ),
        equals('Rafael'),
      );
      expect(
        FslTimeUtils.cleanDriverName(
          '100004 - Kevin Brooks HD(169)**713-555--0105** (100005)',
        ),
        equals('Kevin Brooks'),
      );
      expect(
        FslTimeUtils.cleanDriverName('FB-Truck#69- Leo T(28) -AU1016'),
        equals('Leo T'),
      );
      expect(
        FslTimeUtils.cleanDriverName('DEREK -F823'),
        equals('Derek'),
      );
      expect(
        FslTimeUtils.cleanDriverName(
          '*Andre Wells (11) **713 555 0108**832-555-0109 (100007)',
        ),
        equals('Andre Wells'),
      );
      expect(
        FslTimeUtils.cleanDriverName(
          '*Omar(14)**713 555 0106** 346 555 0107(100006 )',
        ),
        equals('Omar'),
      );
      expect(
        FslTimeUtils.cleanDriverName(
          '*-Dante Fields (800)**832-555-0110**',
        ),
        equals('Dante Fields'),
      );
      expect(
        FslTimeUtils.cleanDriverName(
          'zNathan Price (36)**713 555 0111**',
        ),
        equals('Nathan Price'),
      );
      expect(
        FslTimeUtils.tryExtractCleanDriverName('SHOP () -AUW411'),
        isNull,
      );
      expect(
        FslTimeUtils.tryExtractCleanDriverName('FB-Truck#20'),
        isNull,
      );
    });

    test('DispatchReportBuilder uses clean driver name without callsigns or phones', () {
      final row = DispatchRow(
        resourceId: '0Hn1',
        driverRawName:
            '100004 - Kevin Brooks HD(169)**713-555--0105** (100005)',
        driverCleanName: FslTimeUtils.cleanDriverName(
          '100004 - Kevin Brooks HD(169)**713-555--0105** (100005)',
        ),
        driverPhones: const ['(713) 555-0105'],
        serviceAppointmentId: 'SA1',
        appointmentNumber: 'SA-100',
        callId: '600123',
        territoryGroup: 'HEART',
        workType: 'Tow',
        status: 'Dispatched',
        statusDurationMin: 18,
        isChainSecondLeg: false,
        isRedAlert: false,
        alerts: const [],
      );

      final report = DispatchReportBuilder.buildReport(row);
      expect(
        report,
        equals('Kevin Brooks 600123 Dispatched for 18 mins no ETA not answering'),
      );
      expect(report, isNot(contains('713-555')));
      expect(report, isNot(contains('(169)')));
    });

    test('detects Red Alert hue from GanttColor__c hex', () {
      expect(FslTimeUtils.isRedAlertColor('#FF1E1E'), isTrue);
      expect(FslTimeUtils.isRedAlertColor('#E11D48'), isTrue);
      expect(FslTimeUtils.isRedAlertColor('#228B22'), isFalse);
      expect(FslTimeUtils.isRedAlertColor('#3B82F6'), isFalse);
    });
  });

  group('DriverTruckLinker live fleet edge cases', () {
    test(
      'ignores colliding (14) call-sign and links Omar to OMAR HASSAN (21) instead of Paul Reed (14)',
      () {
        final tarikRow = DispatchRow(
          resourceId: '0HnTEST00000001AA',
          driverRawName: 'Omar(14)**713 555 0106** 346 555 0107(100006 )',
          driverCleanName: FslTimeUtils.cleanDriverName(
            'Omar(14)**713 555 0106** 346 555 0107(100006 )',
          ),
          driverPhones: const ['(713) 555-0106'],
          serviceAppointmentId: 'SA1',
          appointmentNumber: 'SA-1',
          callId: '5001',
          territoryGroup: 'HEART',
          workType: 'Tow',
          status: 'En Route',
          statusDurationMin: 5,
          isChainSecondLeg: false,
          isRedAlert: false,
          alerts: const [],
        );

        final marcusTruck = MotiveVehicle(
          id: 'v_marcus',
          name: 'Paul Reed (14) -PR4356',
          organizationId: '100100',
          organizationName: 'Houston Towing',
          associationGroup: 'HOUSTON TOWING',
          assignedDriverName: 'Paul Reed',
          makeModelYear: 'Ford F-550',
          statusText: 'In Transit (35 mph)',
          motionCategory: VehicleMotionCategory.transit,
          speedMph: 35,
          hasCamera: true,
          isPoweredOff: false,
        );

        final tarikTruck = MotiveVehicle(
          id: 'v_tarik',
          name: 'OMAR HASSAN (21) -PR2091',
          organizationId: '100100',
          organizationName: 'Houston Towing',
          associationGroup: 'HOUSTON TOWING',
          assignedDriverName: 'Omar Hassan',
          makeModelYear: 'Ford F-550',
          statusText: 'Idling',
          motionCategory: VehicleMotionCategory.idle,
          speedMph: 0,
          hasCamera: true,
          isPoweredOff: false,
        );

        final linked = DriverTruckLinker.linkAll(
          rows: [tarikRow],
          vehicles: [marcusTruck, tarikTruck],
        );

        expect(linked.rows.first.linkedTruck, isNotNull);
        expect(
          linked.rows.first.linkedTruck!.motiveVehicleId,
          equals('v_tarik'),
        );
        expect(
          linked.rows.first.linkedTruck!.motiveUnitNumber,
          equals('PR2091'),
        );
      },
    );

    test(
      'prefers active idling DEREK -F823 over stationary Derek Holt (70) -F856',
      () {
        final byronRow = DispatchRow(
          resourceId: '0HnTEST00000002AA',
          driverRawName: 'Derek Holt(70)**713 555 0112**346 555 0113',
          driverCleanName: 'Derek Holt',
          driverPhones: const ['(713) 555-0112'],
          serviceAppointmentId: 'SA2',
          appointmentNumber: 'SA-2',
          callId: '518538',
          territoryGroup: 'HEART',
          workType: 'Flatbed Tow',
          status: 'En Route',
          statusDurationMin: 12,
          isChainSecondLeg: false,
          isRedAlert: false,
          alerts: const [],
        );

        final parkedTruck = MotiveVehicle(
          id: 'v_f856',
          name: 'Derek Holt (70) -F856',
          organizationId: '100100',
          organizationName: 'Houston Towing',
          associationGroup: 'Unassigned',
          assignedDriverName: 'Unassigned',
          makeModelYear: 'Ford',
          statusText: 'Stationary',
          motionCategory: VehicleMotionCategory.stationary,
          speedMph: 0,
          hasCamera: true,
          isPoweredOff: false,
        );

        final activeTruck = MotiveVehicle(
          id: 'v_f823',
          name: 'DEREK -F823',
          organizationId: '100200',
          organizationName: 'HEART',
          associationGroup: 'HEART',
          assignedDriverName: 'Unassigned',
          makeModelYear: 'Ford',
          statusText: 'Idling',
          motionCategory: VehicleMotionCategory.idle,
          speedMph: 0,
          hasCamera: true,
          isPoweredOff: false,
        );

        final linked = DriverTruckLinker.linkAll(
          rows: [byronRow],
          vehicles: [parkedTruck, activeTruck],
        );

        expect(linked.rows.first.linkedTruck, isNotNull);
        expect(
          linked.rows.first.linkedTruck!.motiveVehicleId,
          equals('v_f823'),
        );
        expect(
          linked.rows.first.linkedTruck!.signal,
          equals(LinkVerificationSignal.nameAndActiveMotion),
        );
      },
    );
  });

  group('Rework #1: Stale & Placeholder/Unrealistic ETA Evaluation', () {
    const baseTimeMs = 1760940000000;

    test(
      'hides ETA completely when posted for a previous driver before reassignment',
      () {
        const eta = ParsedChatterEta(
          rawText: 'ETA 20-30 MIN',
          lowMin: 20,
          highMin: 30,
          postedEpochMs: baseTimeMs - (25 * 60000),
          lowTargetEpochMs: baseTimeMs - (5 * 60000),
          highTargetEpochMs: baseTimeMs + (5 * 60000),
        );

        final result = FslChatterParser.evaluateEtaValidity(
          eta: eta,
          currentStatus: 'En Route',
          nowEpochMs: baseTimeMs,
          latestDispatchedEpochMs: baseTimeMs - (10 * 60000),
          wasReassigned: true,
        );

        expect(result.hideCompletely, isTrue);
        expect(result.isExpired, isFalse);
      },
    );

    test(
      'keeps ETA valid when same driver transitions Dispatched -> En Route',
      () {
        const eta = ParsedChatterEta(
          rawText: 'ETA 25-35 MIN',
          lowMin: 25,
          highMin: 35,
          postedEpochMs: baseTimeMs - (10 * 60000),
          lowTargetEpochMs: baseTimeMs + (15 * 60000),
          highTargetEpochMs: baseTimeMs + (25 * 60000),
        );

        final result = FslChatterParser.evaluateEtaValidity(
          eta: eta,
          currentStatus: 'En Route',
          nowEpochMs: baseTimeMs,
          latestDispatchedEpochMs: baseTimeMs - (11 * 60000),
          wasReassigned: false,
          distanceToCallKm: 12.0,
          movementState: 'MOVING',
        );

        expect(result.hideCompletely, isFalse);
        expect(result.isStale, isFalse);
        expect(result.staleReason, isNull);
      },
    );

    test(
      'flags same-driver unrealistic ETA when GPS distance is physically impossible',
      () {
        // Dispatcher gave a 15-min ETA, but driver is 28 km away!
        const eta = ParsedChatterEta(
          rawText: 'ETA 15 MIN',
          lowMin: 15,
          highMin: 15,
          postedEpochMs: baseTimeMs - (2 * 60000),
          lowTargetEpochMs: baseTimeMs + (13 * 60000),
          highTargetEpochMs: baseTimeMs + (13 * 60000),
        );

        final result = FslChatterParser.evaluateEtaValidity(
          eta: eta,
          currentStatus: 'En Route',
          nowEpochMs: baseTimeMs,
          latestDispatchedEpochMs: baseTimeMs - (3 * 60000),
          wasReassigned: false,
          distanceToCallKm: 28.0,
          movementState: 'MOVING',
        );

        expect(result.hideCompletely, isFalse);
        expect(result.isStale, isTrue);
        expect(result.staleReason, equals('UNREALISTIC'));
      },
    );

    test(
      'flags same-driver pre-dispatch placeholder ETA posted > 10m before dispatch',
      () {
        const eta = ParsedChatterEta(
          rawText: 'ETA 30-45 MIN',
          lowMin: 30,
          highMin: 45,
          postedEpochMs: baseTimeMs - (30 * 60000),
          lowTargetEpochMs: baseTimeMs,
          highTargetEpochMs: baseTimeMs + (15 * 60000),
        );

        final result = FslChatterParser.evaluateEtaValidity(
          eta: eta,
          currentStatus: 'Dispatched',
          nowEpochMs: baseTimeMs,
          latestDispatchedEpochMs: baseTimeMs - (5 * 60000),
          wasReassigned: false,
          distanceToCallKm: 5.0,
        );

        expect(result.hideCompletely, isFalse);
        expect(result.isStale, isTrue);
        expect(result.staleReason, equals('PRE-DISPATCH'));
      },
    );
  });

  group(
    'Rework #2: Instant Callback Log + Cancelled, Red Alert & Territory Indicators',
    () {
      test(
        'populates completed and cancelled calls instantly from getDelta with wait/on-scene, territory, Red Alert, and Cancelled indicators',
        () {
          final repo = FslRepository(
            apiClient: FslApiClient(authService: AuthSessionService()),
          );
          const nowMs = 1760940000000;
          final schedWallMs = FslTimeUtils.epochMsToSfWallClockMs(
            nowMs - (50 * 60000),
          );
          final arrivedWallMs = FslTimeUtils.epochMsToSfWallClockMs(
            nowMs - (20 * 60000),
          );
          const clearedEpochMs = nowMs - (5 * 60000);

          final completedDto = FslServiceAppointmentDto.fromJson({
            'Id': '08pCompleted1',
            'Resource': '0HnDriver1',
            'ResourceName': 'Jordan Miles (71)**713 555 0101',
            'Fields': {
              'Id': '08pCompleted1',
              'AppointmentNumber': 'SA-9001',
              'D3_Call_ID__c': '550011',
              'Status': 'Cleared',
              'WorkType': {'s': 1, 'v': 'Flatbed Tow'},
              'ServiceTerritory.Name': '631252 - HOUSTON EMERGENCY AUTO RESCUE',
              'GanttColor__c': '#FF1E1E', // Red Alert!
              'Phone_Number__c': '(832) 555-0199',
              'Member_Benefit_Level__c': 'Premier',
              'FSL_Member_Vehicle_Name__c': '2022 Ford F-150 Black',
              'SchedStartTime': schedWallMs,
              'ActualStartTime': arrivedWallMs,
              'LastModifiedDate': clearedEpochMs,
              'ParentRecordId': '0WOParent1',
            },
          });

          final cancelledDto = FslServiceAppointmentDto.fromJson({
            'Id': '08pCanceled2',
            'Resource': '0HnDriver2',
            'ResourceName': 'Omar Hassan (21)**713 555 0106',
            'Fields': {
              'Id': '08pCanceled2',
              'AppointmentNumber': 'SA-9002',
              'D3_Call_ID__c': '550022',
              'Status': 'Canceled',
              'WorkType': 'Battery Service',
              'ServiceTerritory.Name': '632300 - HOUSTON TOWING',
              'GanttColor__c': '#228B22',
              'Phone_Number__c': '(713) 555-0144',
              'Member_Benefit_Level__c': 'Plus',
              'FSL_Member_Vehicle_Name__c': '2019 Honda Civic Silver',
              'SchedStartTime': schedWallMs,
              'LastModifiedDate': nowMs - (2 * 60000),
              'ParentRecordId': '0WOParent2',
            },
          });

          repo.cacheWorkOrderLightbox(
            '0WOParent1',
            const ParsedWorkOrderLightbox(memberName: 'Jane Doe'),
          );

          repo.ingestAppointmentsAndResources(
            appointments: [completedDto, cancelledDto],
            resources: const [],
            nowEpochMs: nowMs,
          );
          repo.evaluateCurrentState(nowEpochMs: nowMs);

          final cleared = repo.clearedCalls;
          expect(cleared.length, equals(2));

          // Newest first -> cancelledDto (cleared 2m ago), then completedDto (cleared 5m ago)
          final cancelledCall = cleared[0];
          expect(cancelledCall.callId, equals('550022'));
          expect(cancelledCall.isCancelled, isTrue);
          expect(cancelledCall.isRedAlert, isFalse);
          expect(cancelledCall.territory, equals('632300 - HOUSTON TOWING'));
          expect(cancelledCall.driverName, equals('Omar Hassan'));
          expect(cancelledCall.benefitLevel, equals('Plus'));

          final completedCall = cleared[1];
          expect(completedCall.callId, equals('550011'));
          expect(completedCall.isCancelled, isFalse);
          expect(completedCall.isRedAlert, isTrue);
          expect(
            completedCall.territory,
            equals('631252 - HOUSTON EMERGENCY AUTO RESCUE'),
          );
          expect(completedCall.memberName, equals('Jane Doe'));
          expect(completedCall.memberPhone, equals('(832) 555-0199'));
          expect(completedCall.benefitLevel, equals('Premier'));
          expect(completedCall.workType, equals('Flatbed Tow'));
          expect(completedCall.memberVehicle, equals('2022 Ford F-150 Black'));
          expect(
            completedCall.waitDurationMin,
            equals(30),
          ); // 50m ago -> 20m ago
          expect(
            completedCall.onSceneDurationMin,
            equals(15),
          ); // 20m ago -> 5m ago
        },
      );

      test(
        'ignores Salesforce ActualStartTime == SchedStartTime and computes exact Member waited & On scene from SA Chatter feed',
        () {
          final repo = FslRepository(
            apiClient: FslApiClient(authService: AuthSessionService()),
          );
          // 11:00 AM Central on Oct 20, 2025
          final nowEpochMs = FslTimeUtils.sfWallClockMsToEpochMs(
            DateTime.utc(2025, 10, 20, 11, 0).millisecondsSinceEpoch,
          );
          final bogusEqualWallMs = FslTimeUtils.epochMsToSfWallClockMs(
            nowEpochMs - (40 * 60000),
          );

          final saDto = FslServiceAppointmentDto.fromJson({
            'Id': '08pRealSf1',
            'Resource': '0HnDrv1',
            'ResourceName': '100002 - Rafael(37) **832-555-0103**',
            'Fields': {
              'Id': '08pRealSf1',
              'AppointmentNumber': 'SA-9999',
              'D3_Call_ID__c': '778899',
              'Status': 'Cleared',
              'WorkType': 'Battery Service',
              'SchedStartTime': bogusEqualWallMs,
              // Salesforce sets ActualStartTime == SchedStartTime!
              'ActualStartTime': bogusEqualWallMs,
              'LastModifiedDate': nowEpochMs - (5 * 60000),
            },
          });

          const feedHtml = '''
            <div class="feeditem">
              changed Status from Spotted to Dispatched.
              <span class="feeditemtimestamp">Today at 10:10 AM</span>
            </div>
            <div class="feeditem">
              changed Status from Dispatched to En Route.
              <span class="feeditemtimestamp">Today at 10:15 AM</span>
            </div>
            <div class="feeditem">
              changed Status from En Route to On Location.
              <span class="feeditemtimestamp">Today at 10:38 AM</span>
            </div>
            <div class="feeditem">
              changed Status from On Location to Cleared.
              <span class="feeditemtimestamp">Today at 10:52 AM</span>
            </div>
          ''';

          final parsedFeed = FslChatterParser.parseStatusTimesFromFeed(
            feedHtml,
            nowEpochMs: nowEpochMs,
          );
          repo.cacheSaFeedTimes('08pRealSf1', parsedFeed);

          repo.ingestAppointmentsAndResources(
            appointments: [saDto],
            resources: const [],
            nowEpochMs: nowEpochMs,
          );
          repo.evaluateCurrentState(nowEpochMs: nowEpochMs);

          final call = repo.clearedCalls.single;
          expect(call.driverName, equals('Rafael'));
          // Spotted/Dispatched at 10:10 AM -> On Location at 10:38 AM = 28 min wait
          expect(call.waitDurationMin, equals(28));
          // On Location at 10:38 AM -> Cleared at 10:52 AM = 14 min on scene
          expect(call.onSceneDurationMin, equals(14));
        },
      );
    },
  );

  group('Rework #3 & #4: Motive Multi-Angle Camera, Age Marks & Simple Report', () {
    const nowMs = 1760940000000;

    test(
      'selects Driver Cam as main hero view, puts all other angles as thumbnails above it, and formats short age marks (Now, 2m, 5m)',
      () {
        final vNow = MotiveVehicle(
          id: '9001',
          name: 'FB-TRUCK12',
          organizationId: '100200',
          organizationName: 'HEART',
          associationGroup: 'ALL AMERICAN',
          assignedDriverName: 'Unassigned',
          makeModelYear: 'Ford F-650',
          statusText: 'In Transit (55.0 mph)',
          motionCategory: VehicleMotionCategory.transit,
          speedMph: 55.0,
          hasCamera: true,
          isPoweredOff: false,
          cameraPathsByAngle: const {
            'driver': '/tmp/9001_driver.jpg',
            'road': '/tmp/9001_road.jpg',
            'rear': '/tmp/9001_rear.jpg',
            'side_left': '/tmp/9001_side_left.jpg',
          },
          lastRefreshedEpochMs: nowMs - 30000, // 30s ago -> Now
        );

        expect(vNow.mainCameraEntry?.key, equals('driver'));
        expect(
          vNow.thumbnailCameraEntries.map((e) => e.key).toList(),
          equals(['road', 'rear', 'side_left']),
        );
        expect(vNow.shortAgeLabel(nowEpochMs: nowMs), equals('Now'));

        final v2m = vNow.copyWith(lastRefreshedEpochMs: nowMs - (2 * 60000));
        expect(v2m.shortAgeLabel(nowEpochMs: nowMs), equals('2m'));

        final v5m = vNow.copyWith(lastRefreshedEpochMs: nowMs - (5 * 60000));
        expect(v5m.shortAgeLabel(nowEpochMs: nowMs), equals('5m'));
      },
    );

    test(
      'builds simple report text with Associated Driver + URL when driver exists, and URL only when unassigned',
      () {
        final withDriver = MotiveVehicle(
          id: '1001',
          name: 'OMAR HASSAN (21) -PR2091',
          organizationId: '100100',
          organizationName: 'Houston Towing',
          associationGroup: 'HOUSTON TOWING',
          assignedDriverName: 'Omar Hassan',
          makeModelYear: 'Ford F-550',
          statusText: 'In Transit (45 mph)',
          motionCategory: VehicleMotionCategory.transit,
          speedMph: 45,
          hasCamera: true,
          isPoweredOff: false,
        );

        expect(
          MotiveReportBuilder.buildSimpleReportText(withDriver),
          equals(
            'Driver: Omar Hassan\n'
            'https://app.gomotive.com/en-US/#/fleetview/map/vehicle/1001-null-null/1001/live',
          ),
        );

        final withoutDriver = MotiveVehicle(
          id: '2002',
          name: 'FB-TRUCK09',
          organizationId: '100200',
          organizationName: 'HEART',
          associationGroup: 'ALL AMERICAN',
          assignedDriverName: 'Unassigned',
          makeModelYear: 'Ford F-650',
          statusText: 'Idling',
          motionCategory: VehicleMotionCategory.idle,
          speedMph: 0,
          hasCamera: true,
          isPoweredOff: false,
        );

        expect(
          MotiveReportBuilder.buildSimpleReportText(withoutDriver),
          equals(
            'https://app.gomotive.com/en-US/#/fleetview/map/vehicle/2002-null-null/2002/live',
          ),
        );
      },
    );

    test(
      'MotiveVehicleParser parses current_state ground_speed_kph, entity_state, and dashcam_info vg_powered_off',
      () {
        const session = MotiveAccountSession(
          organizationId: '100200',
          organizationName: 'HEART',
          authToken: 'tok_test',
        );

        final parsed = MotiveVehicleParser.fromApiJson(
          {
            'vehicle': {
              'id': 7788,
              'number': 'LS-TRUCK04',
              'current_state': {
                'entity_state': 'driving',
                'ground_speed_kph': 100.0,
              },
              'dashcam_info': {
                'health_sub_status_key': 'vg_powered_off',
              },
              'eld_device': {
                'id': 4455,
                'identifier': 'ELD-7788',
              },
            },
          },
          account: session,
        );

        expect(parsed.id, equals('7788'));
        expect(parsed.motionCategory, equals(VehicleMotionCategory.transit));
        expect(parsed.speedMph, closeTo(62.1, 0.2));
        expect(parsed.isPoweredOff, isTrue);
        expect(parsed.eldIdentifier, equals('ELD-7788'));
        expect(parsed.associationGroup, equals('ALL AMERICAN'));
      },
    );
  });

  group('AlertNotificationService deduplication & preferences', () {
    test('deduplicates repeated alerts within 15-minute cooldown and respects mute toggle', () async {
      SharedPreferences.setMockInitialValues({});
      final service = AlertNotificationService();
      await service.initialize();
      expect(service.notificationsEnabled, isTrue);

      const sampleAlert = DispatchAlert(
        type: DispatchAlertType.dispatchOverdue,
        driverName: 'Kevin Brooks (169)**713-555-0105',
        driverId: '0HnDrv1',
        callId: '600123',
        appointmentNumber: 'SA-100',
        status: 'Dispatched',
        workType: 'Tow',
        detail: 'Dispatched for 18 min without En Route',
        sinceEpochMs: 1760940000000,
        durationMin: 18,
      );

      // First evaluation triggers 1 new alert
      final firstCount = await service.processAlerts([sampleAlert]);
      expect(firstCount, equals(1));

      // Immediate second evaluation with the same alert is suppressed by cooldown
      final secondCount = await service.processAlerts([sampleAlert]);
      expect(secondCount, equals(0));

      // Disabling notifications suppresses new alerts too
      await service.setNotificationsEnabled(false);
      const secondAlert = DispatchAlert(
        type: DispatchAlertType.etaExpired,
        driverName: 'Rafael (37)',
        driverId: '0HnDrv2',
        callId: '600999',
        appointmentNumber: 'SA-200',
        status: 'En Route',
        workType: 'Battery',
        detail: 'ETA expired 12 min ago',
        sinceEpochMs: 1760940000000,
        durationMin: 12,
      );
      final mutedCount = await service.processAlerts([secondAlert]);
      expect(mutedCount, equals(0));
    });
  });
}
