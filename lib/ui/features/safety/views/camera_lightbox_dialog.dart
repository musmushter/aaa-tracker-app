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
    _keyboardFocusNode.dispose();
    super.dispose();
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
    setState(() {
      _currentIndex =
          (_currentIndex + delta + _vehicles.length) % _vehicles.length;
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
    final availableEntries = v.availableCameraEntries;
    final ageLabel = v.shortAgeLabel();
    final driverName = v.effectiveDriverName;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      // Exclude inner buttons from stealing directional arrow key focus
      child: ExcludeFocus(
        excluding: true,
        child: Dialog(
          backgroundColor: const Color(0xFF14161A),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 22,
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
                // Top Bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E2127),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF33373F)),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    v.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFE8E8E8),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _buildMetaBadge(
                                  v.organizationName,
                                  const Color(0xFF3B82F6),
                                ),
                                if (v.associationGroup.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  _buildMetaBadge(
                                    v.associationGroup,
                                    const Color(0xFF10B981),
                                  ),
                                ],
                                if (ageLabel.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  _buildCornerAgeBadge(ageLabel),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${driverName != null ? "Driver: $driverName  •  " : ""}${v.statusText}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF8B909C),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_vehicles.length > 1) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF14161A),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF33373F)),
                          ),
                          child: Text(
                            'Truck ${_currentIndex + 1} / ${_vehicles.length}  (← / →)',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFE8E8E8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      IconButton(
                        tooltip: 'Close (Esc)',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),

              // View Mode & Camera Angle Selector Strip
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF181B20),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF33373F)),
                  ),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text(
                          'Stitched View (Driver + Secondary Cams)',
                          style: TextStyle(fontSize: 12),
                        ),
                        selected: _selectedAngle == 'stitched',
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) =>
                            setState(() => _selectedAngle = 'stitched'),
                      ),
                      const SizedBox(width: 8),
                      ...availableEntries.map((entry) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              entry.label,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _selectedAngle == entry.key,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) =>
                                setState(() => _selectedAngle = entry.key),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),

              // Main Stage
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: _vehicles.length > 1 ? 68 : 20,
                        vertical: 14,
                      ),
                      child: _selectedAngle == 'stitched'
                          ? _buildStitchedStage(v, ageLabel)
                          : _buildSingleAngleStage(v, ageLabel),
                    ),
                    if (_vehicles.length > 1) ...[
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E2127),
                  border: Border(
                    top: BorderSide(color: Color(0xFF33373F)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: SelectableText(
                        driverName != null
                            ? 'Driver: $driverName  •  ${v.liveMotiveUrl}'
                            : v.liveMotiveUrl,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF8B909C),
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF46A758),
                            foregroundColor: Colors.white,
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
                              : const Icon(Icons.send_rounded, size: 16),
                          label: const Text('Report (Copy Image + Info)'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
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
                              : const Icon(Icons.refresh, size: 16),
                          label: const Text('Refresh Cam (R)'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Renders the stitched layout:
  /// - Secondary cameras (`Road Cam`, etc.) as compact, true `16:9` thumbnails
  ///   in a top strip (never stretched across the screen or cropped).
  /// - Main `Driver Cam` below in true `16:9` aspect ratio with `BoxFit.contain`.
  Widget _buildStitchedStage(MotiveVehicle v, String ageLabel) {
    final mainEntry = v.mainCameraEntry;
    final thumbs = v.thumbnailCameraEntries;

    if (mainEntry == null || !File(mainEntry.path).existsSync()) {
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

    return LayoutBuilder(
      builder: (context, constraints) {
        // Reserve ~24% of height (clamped 125..210px) for top secondary thumbnails
        final double thumbHeight = thumbs.isNotEmpty
            ? (constraints.maxHeight * 0.24).clamp(125.0, 210.0)
            : 0.0;

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (thumbs.isNotEmpty) ...[
              SizedBox(
                height: thumbHeight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < thumbs.length; i++) ...[
                        if (i > 0) const SizedBox(width: 12),
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () =>
                                setState(() => _selectedAngle = thumbs[i].key),
                            child: _buildCameraFrame(
                              filePath: thumbs[i].path,
                              label: thumbs[i].label,
                              ageLabel: ageLabel,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _buildCameraFrame(
                    filePath: mainEntry.path,
                    label: mainEntry.label,
                    ageLabel: ageLabel,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSingleAngleStage(MotiveVehicle v, String ageLabel) {
    final path =
        v.cameraPathsByAngle[_selectedAngle] ?? v.mainCameraEntry?.path;
    final label = MotiveVehicle.labelForAngle(_selectedAngle);

    if (path == null || !File(path).existsSync()) {
      return const Center(
        child: Text(
          'No snapshot captured yet for this camera angle.',
          style: TextStyle(color: Color(0xFF8B909C)),
        ),
      );
    }

    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 4.0,
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: _buildCameraFrame(
            filePath: path,
            label: label,
            ageLabel: ageLabel,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  Widget _buildCameraFrame({
    required String filePath,
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
            key: ValueKey('$filePath-${File(filePath).lastModifiedSync().millisecondsSinceEpoch}'),
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

  Widget _buildMetaBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
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
