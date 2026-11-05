import 'package:flutter/material.dart';
import 'data/repositories/fsl_repository.dart';
import 'data/repositories/motive_repository.dart';
import 'data/services/auth_session_service.dart';
import 'data/services/fsl_api_client.dart';
import 'data/services/motive_api_client.dart';
import 'data/services/snapshot_storage_service.dart';
import 'domain/use_cases/fsl_time_utils.dart';
import 'ui/core/app_theme.dart';
import 'ui/features/shell/view_models/app_shell_view_model.dart';
import 'ui/features/shell/views/app_shell_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Cap decoded image memory at 60 MB so camera grids never exhaust RAM/GPU texture cache.
  PaintingBinding.instance.imageCache.maximumSize = 80;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20;
  FslTimeUtils.ensureInitialized();

  final authService = AuthSessionService();
  final snapshotStorage = SnapshotStorageService();
  final fslClient = FslApiClient(authService: authService);
  final motiveClient = MotiveApiClient(snapshotStorage: snapshotStorage);

  final fslRepository = FslRepository(apiClient: fslClient);
  final motiveRepository = MotiveRepository(
    apiClient: motiveClient,
    authService: authService,
    snapshotStorage: snapshotStorage,
  );

  final shellViewModel = AppShellViewModel(
    authService: authService,
    fslRepository: fslRepository,
    motiveRepository: motiveRepository,
  )..initialize();

  runApp(AaaTrackerApp(viewModel: shellViewModel));
}

class AaaTrackerApp extends StatelessWidget {
  const AaaTrackerApp({super.key, required this.viewModel});

  final AppShellViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AAA Dispatch & Fleet Safety',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: AppShellView(viewModel: viewModel),
    );
  }
}
