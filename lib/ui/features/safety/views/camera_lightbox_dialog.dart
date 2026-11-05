import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../data/services/motive_report_share_service.dart';
import '../../../../domain/models/motive_vehicle.dart';

/// Multi-angle & stitched dashcam inspection popup modal.
///
/// - Left / Right arrow keys navigate directly between truck cameras (never
///   traversing individual UI buttons).
/// - Stitched view renders secondary thumbnails (`Road Cam`, etc.) in true
///   `16:9` aspect ratio above the `16:9` main `Driver Cam` with `BoxFit.contain`
///   so zero pixels are cropped or squished.
class CameraLightboxDialog extends StatefulWidget {
  const CameraLightboxDialog({
    super.key,
    required this.vehicles,
    required this.initialIndex,
    required this.onRefreshCamera,
    this.resolveLatestVehicle,
    this.initialAngleKey = 'stitched',
    this.autoRefreshIfMissing = true,
  });

  final List<MotiveVehicle> vehicles;
  final int initialIndex;
  final Future<MotiveVehicle?> Function(String vehicleId) onRefreshCamera;
  final MotiveVehicle? Function(String vehicleId)? resolveLatestVehicle;
  final String initialAngleKey;
  final bool autoRefreshIfMissing;

  @override
  State<CameraLightboxDialog> createState() => _CameraLightboxDialogState();
}

class _CameraLightboxDialogState extends State<CameraLightboxDialog> {
  final FocusNode _keyboardFocusNode = FocusNode();
  final TransformationController _zoomController = TransformationController();
  TapDownDetails? _doubleTapDetails;
  late List<MotiveVehicle> _vehicles;
  late int _currentIndex;
  late String _selectedAngle;
  bool _isReporting = false;
  bool _isRefreshingCam = false;

  @override
  void initState() {
    super.initState();
    _vehicles = List<MotiveVehicle>.from(widget.vehicles);
    _currentIndex = widget.initialIndex.clamp(0, _vehicles.length - 1);
    _selectedAngle = widget.initialAngleKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keyboardFocusNode.requestFocus();
      if (widget.autoRefreshIfMissing && !_currentVehicle.hasImages) {
        _triggerRefreshCam();
      }
    });
  }

  @override
  void dispose() {
    _zoomController.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _enterZoomView(String angleKey) {
    _zoomController.value = Matrix4.identity();
    setState(() {
      _selectedAngle = angleKey;
    });
  }

  void _exitZoomView() {
    _zoomController.value = Matrix4.identity();
    setState(() {
      _selectedAngle = 'stitched';
    });
  }

  void _handleDoubleTapZoom() {
    final currentScale = _zoomController.value.getMaxScaleOnAxis();
    if (currentScale > 1.05) {
      _zoomController.value = Matrix4.identity();
      return;
    }
    final pos = _doubleTapDetails?.localPosition;
    if (pos == null) {
      _zoomController.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
      return;
    }
    const targetScale = 2.5;
    final dx = -pos.dx * (targetScale - 1.0);
    final dy = -pos.dy * (targetScale - 1.0);
    _zoomController.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0.0, 1.0)
      ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
  }

  MotiveVehicle get _currentVehicle {
    final base = _vehicles[_currentIndex];
    final latest = widget.resolveLatestVehicle?.call(base.id);
    if (latest != null) {
      _vehicles[_currentIndex] = latest;
      return latest;
    }
    return base;
  }

  void _stepVehicle(int delta) {
    if (_vehicles.length <= 1) return;
    _zoomController.value = Matrix4.identity();
    setState(() {
      _currentIndex =
          (_currentIndex + delta + _vehicles.length) % _vehicles.length;
      _selectedAngle = 'stitched';
    });
    _keyboardFocusNode.requestFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _stepVehicle(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _stepVehicle(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR && event is KeyDownEvent) {
      _triggerRefreshCam();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<MotiveVehicle?> _triggerRefreshCam() async {
    if (_isRefreshingCam) return null;
    final vehicleId = _currentVehicle.id;
    setState(() => _isRefreshingCam = true);
    try {
      final updated = await widget.onRefreshCamera(vehicleId);
      if (mounted && updated != null) {
        setState(() {
          final idx = _vehicles.indexWhere((v) => v.id == vehicleId);
          if (idx != -1) {
            _vehicles[idx] = updated;
          }
        });
      }
      return updated;
    } finally {
      if (mounted) {
        setState(() => _isRefreshingCam = false);
        _keyboardFocusNode.requestFocus();
      }
    }
  }

  Future<void> _handleSingleButtonReport() async {
    if (_isReporting) return;
    setState(() => _isReporting = true);
    try {
      final result = await MotiveReportShareService.executeSingleButtonReport(
        _currentVehicle,
        onEnsureSnapshots: (vehicleId) => widget.onRefreshCamera(vehicleId),
      );
      if (!mounted) return;
      setState(() {});
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
        setState(() => _isReporting = false);
        _keyboardFocusNode.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _currentVehicle;
    final ageLabel = v.shortAgeLabel();
    final driverName = v.effectiveDriverName;
    final isWide = MediaQuery.sizeOf(context).width >= 700;
    final statusColor = v.isPoweredOff
        ? const Color(0xFFE5484D)
        : (v.motionCategory == VehicleMotionCategory.transit
              ? const Color(0xFF46A758)
              : (v.motionCategory == VehicleMotionCategory.idle
                    ? const Color(0xFFF5A623)
                    : const Color(0xFF94A3B8)));

    return PopScope(
      canPop: _selectedAngle == 'stitched',
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedAngle != 'stitched') {
          _exitZoomView();
        }
      },
      child: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        // Exclude inner buttons from stealing directional arrow key focus
        child: ExcludeFocus(
          excluding: true,
          child: Dialog(
            backgroundColor: const Color(0xFF14161A),
            insetPadding: EdgeInsets.symmetric(
              horizontal: isWide ? 28 : 10,
              vertical: isWide ? 22 : 12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Color(0xFF33373F), width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 840),
              child: Column(
                children: [
                  // Top Bar (Row 1: Name + Pinned < 1/11 > X, Row 2: Full-width Status + Org + Age)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E2127),
                      border: Border(
                        bottom: BorderSide(color: Color(0xFF33373F)),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                v.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFE8E8E8),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (_vehicles.length > 1) ...[
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!isWide)
                                    SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Previous Truck',
                                        onPressed: () => _stepVehicle(-1),
                                        icon: const Icon(
                                          Icons.chevron_left,
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                  Container(
                                    width: isWide ? 164 : 54,
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF14161A),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: const Color(0xFF33373F),
                                      ),
                                    ),
                                    child: Text(
                                      isWide
                                          ? 'Truck ${_currentIndex + 1} / ${_vehicles.length}  (← / →)'
                                          : '${_currentIndex + 1}/${_vehicles.length}',
                                      maxLines: 1,
                                      overflow: TextOverflow.clip,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFE8E8E8),
                                      ),
                                    ),
                                  ),
                                  if (!isWide)
                                    SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Next Truck',
                                        onPressed: () => _stepVehicle(1),
                                        icon: const Icon(
                                          Icons.chevron_right,
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 4),
                            ],
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                tooltip: 'Close (Esc)',
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close, size: 20),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        // Full-width Row 2 so Status is always 100% visible
                        SizedBox(
                          height: 20,
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: statusColor.withValues(alpha: 0.55),
                                  ),
                                ),
                                child: Text(
                                  v.isPoweredOff
                                      ? 'Powered Off'
                                      : v.statusText,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: statusColor,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  [
                                    v.organizationName,
                                    if (ageLabel.isNotEmpty) ageLabel,
                                    if (driverName != null)
                                      'Driver: $driverName',
                                  ].join('  •  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: Color(0xFF93C5FD),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Main Stage (Default: Road Cam stretched on top + Driver Cam stretched below; Tap any to zoom)
                  Expanded(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: isWide
                                ? (_vehicles.length > 1 ? 68 : 20)
                                : 6,
                            vertical: isWide ? 10 : 6,
                          ),
                          child: _selectedAngle == 'stitched'
                              ? _buildStitchedStage(v, ageLabel)
                              : _buildSingleAngleStage(v, ageLabel),
                        ),
                        if (_vehicles.length > 1 && isWide) ...[
                          Positioned(
                            left: 14,
                            child: IconButton.filledTonal(
                              tooltip: 'Previous Truck (←)',
                              onPressed: () => _stepVehicle(-1),
                              icon: const Icon(Icons.chevron_left, size: 28),
                            ),
                          ),
                          Positioned(
                            right: 14,
                            child: IconButton.filledTonal(
                              tooltip: 'Next Truck (→)',
                              onPressed: () => _stepVehicle(1),
                              icon: const Icon(Icons.chevron_right, size: 28),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Bottom Action Bar
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: isWide ? 14 : 10,
                      vertical: isWide ? 10 : 7,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E2127),
                      border: Border(
                        top: BorderSide(color: Color(0xFF33373F)),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: isWide
                          ? MainAxisAlignment.spaceBetween
                          : MainAxisAlignment.center,
                      children: [
                        if (isWide)
                          Expanded(
                            child: Text(
                              driverName != null
                                  ? 'Driver: $driverName  •  ${v.liveMotiveUrl}'
                                  : v.liveMotiveUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF8B909C),
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        if (isWide) const SizedBox(width: 10),
                        Flexible(
                          child: Row(
                            mainAxisSize: isWide
                                ? MainAxisSize.min
                                : MainAxisSize.max,
                            children: [
                              if (!isWide)
                                Expanded(
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFF46A758),
                                      foregroundColor: Colors.white,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: _isReporting
                                        ? null
                                        : _handleSingleButtonReport,
                                    icon: _isReporting
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.send_rounded,
                                            size: 15,
                                          ),
                                    label: const Text('Report'),
                                  ),
                                )
                              else
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF46A758),
                                    foregroundColor: Colors.white,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: _isReporting
                                      ? null
                                      : _handleSingleButtonReport,
                                  icon: _isReporting
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.send_rounded,
                                          size: 15,
                                        ),
                                  label: const Text(
                                    'Report (Copy Image + Info)',
                                  ),
                                ),
                              const SizedBox(width: 8),
                              if (!isWide)
                                Expanded(
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: _isRefreshingCam
                                        ? null
                                        : _triggerRefreshCam,
                                    icon: _isRefreshingCam
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.refresh, size: 15),
                                    label: const Text('Refresh Cam'),
                                  ),
                                )
                              else
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: _isRefreshingCam
                                      ? null
                                      : _triggerRefreshCam,
                                  icon: _isRefreshingCam
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.refresh, size: 15),
                                  label: const Text('Refresh Cam (R)'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Renders the default stacked layout:
  /// - Secondary camera (`Road Cam`, etc.) fit to the full width of the screen
  ///   on top while preserving its native `16:9` aspect ratio.
  /// - Main `Driver Cam` fit to the full width of the screen below while
  ///   preserving its native `16:9` aspect ratio.
  /// - Pressing any camera view opens it in full-stage pinch/double-tap zoom mode.
  Widget _buildStitchedStage(MotiveVehicle v, String ageLabel) {
    final mainEntry = v.mainCameraEntry;
    final thumbs = v.thumbnailCameraEntries;

    if (mainEntry == null || mainEntry.path.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              size: 40,
              color: Color(0xFF8B909C),
            ),
            const SizedBox(height: 10),
            Text(
              'No snapshot captured yet for ${v.name} (${v.cameraStatusText}).',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8B909C)),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isRefreshingCam ? null : _triggerRefreshCam,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Capture Camera Snapshot Now'),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (thumbs.isNotEmpty) ...[
          Flexible(
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < thumbs.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Flexible(
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _enterZoomView(thumbs[i].key),
                          child: _buildCameraFrame(
                            filePath: thumbs[i].path,
                            revisionToken: v.lastRefreshedEpochMs,
                            cacheWidth: 1280,
                            label: thumbs[i].label,
                            ageLabel: ageLabel,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Flexible(
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _enterZoomView(mainEntry.key),
                child: _buildCameraFrame(
                  filePath: mainEntry.path,
                  revisionToken: v.lastRefreshedEpochMs,
                  cacheWidth: 1280,
                  label: mainEntry.label,
                  ageLabel: ageLabel,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSingleAngleStage(MotiveVehicle v, String ageLabel) {
    final path =
        v.cameraPathsByAngle[_selectedAngle] ?? v.mainCameraEntry?.path;
    final label = MotiveVehicle.labelForAngle(_selectedAngle);

    if (path == null || path.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No snapshot captured yet for this camera angle.',
              style: TextStyle(color: Color(0xFF8B909C)),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: _exitZoomView,
              icon: const Icon(Icons.fullscreen_exit_rounded, size: 16),
              label: const Text('Back to Split View'),
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onDoubleTapDown: (details) => _doubleTapDetails = details,
          onDoubleTap: _handleDoubleTapZoom,
          child: InteractiveViewer(
            transformationController: _zoomController,
            minScale: 1.0,
            maxScale: 6.0,
            panEnabled: true,
            scaleEnabled: true,
            child: Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _buildCameraFrame(
                  filePath: path,
                  revisionToken: v.lastRefreshedEpochMs,
                  cacheWidth: 1600,
                  label: label,
                  ageLabel: ageLabel,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: InkWell(
            onTap: _exitZoomView,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xE614161A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF3B82F6)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fullscreen_exit_rounded,
                    size: 16,
                    color: Color(0xFF93C5FD),
                  ),
                  SizedBox(width: 5),
                  Text(
                    'Back to Split View',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFE8E8E8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraFrame({
    required String filePath,
    required int? revisionToken,
    required int cacheWidth,
    required String label,
    required String ageLabel,
    required BoxFit fit,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0C0E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF33373F)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(filePath),
            key: ValueKey('$filePath-${revisionToken ?? 0}'),
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            fit: fit,
          ),
          if (ageLabel.isNotEmpty)
            Positioned(
              top: 8,
              right: 8,
              child: _buildCornerAgeBadge(ageLabel),
            ),
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xD914161A),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFF33373F)),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE8E8E8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCornerAgeBadge(String ageLabel) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xD914161A),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF46A758)),
      ),
      child: Text(
        ageLabel,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Color(0xFF46A758),
        ),
      ),
    );
  }
}
