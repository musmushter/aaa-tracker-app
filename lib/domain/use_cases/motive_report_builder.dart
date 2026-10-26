import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import '../models/motive_vehicle.dart';

/// Builds the standalone Motive Safety Console camera report:
/// 1. Simple report text: Associated driver (if one exists) + Motive live URL.
/// 2. Stitched camera collage PNG: Driver cam as the main full-width view,
///    any other available camera views as small thumbnails above it, and a
///    corner mark showing when the snapshot was last updated (`Now`, `2m`, `5m`, etc.).
class MotiveReportBuilder {
  /// Builds the simple text caption for a camera report:
  /// Associated driver (if one exists) and the live Motive URL.
  /// The user types the offense themselves if needed.
  static String buildSimpleReportText(MotiveVehicle vehicle) {
    final driver = vehicle.effectiveDriverName;
    if (driver != null && driver.isNotEmpty) {
      return 'Driver: $driver\n${vehicle.liveMotiveUrl}';
    }
    return vehicle.liveMotiveUrl;
  }

  /// Alias preserved for compatibility.
  static String buildWhatsAppCaption(MotiveVehicle vehicle) =>
      buildSimpleReportText(vehicle);

  /// Renders a stitched PNG combining:
  /// - Any secondary camera views (`road`, `front_narrow`, `rear`, `side_left`,
  ///   `side_right`) as small thumbnails in a top row.
  /// - The main camera view (`driver` cam if available, otherwise primary view)
  ///   as the large hero view underneath.
  /// - A corner age badge (`Now`, `2m`, `5m`, etc.) in the top-right corner.
  ///
  /// Returns `null` if no valid snapshot files exist on disk for [vehicle].
  static Future<Uint8List?> renderStitchedCameraPng(
    MotiveVehicle vehicle, {
    int? nowEpochMs,
  }) async {
    final mainEntry = vehicle.mainCameraEntry;
    if (mainEntry == null) return null;

    final mainImage = await _decodeFileImage(mainEntry.path);
    if (mainImage == null) return null;

    final thumbEntries = vehicle.thumbnailCameraEntries;
    final loadedThumbs = <({String label, ui.Image image})>[];
    for (final entry in thumbEntries) {
      final decoded = await _decodeFileImage(entry.path);
      if (decoded != null) {
        loadedThumbs.add((label: entry.label, image: decoded));
      }
    }

    const double canvasWidth = 1280.0;
    const double outerPad = 16.0;
    const double gap = 12.0;
    const double innerWidth = canvasWidth - (outerPad * 2);

    // Calculate top thumbnail strip dimensions preserving each camera's true aspect ratio
    final bool hasThumbs = loadedThumbs.isNotEmpty;
    final int thumbCount = loadedThumbs.length;
    const double maxThumbHeight = 234.0; // ~416x234 for 16:9 thumbnail above 1248x702 main
    final thumbAspects = <double>[];
    double thumbHeight = 0.0;
    if (hasThumbs) {
      for (final item in loadedThumbs) {
        final w = item.image.width.toDouble();
        final h = item.image.height.toDouble();
        thumbAspects.add((w > 0 && h > 0) ? (w / h) : (16.0 / 9.0));
      }
      final totalAspect = thumbAspects.fold<double>(0.0, (a, b) => a + b);
      final availableWidth = innerWidth - (gap * (thumbCount - 1));
      final fittedHeight = totalAspect > 0
          ? (availableWidth / totalAspect)
          : maxThumbHeight;
      thumbHeight = fittedHeight.clamp(120.0, maxThumbHeight);
    }

    // Main driver camera dimensions preserving native aspect ratio (typically 16:9 -> 1248x702)
    final double mainAspect =
        (mainImage.width > 0 && mainImage.height > 0)
        ? (mainImage.width / mainImage.height)
        : (16.0 / 9.0);
    final double mainHeight = (innerWidth / mainAspect).clamp(400.0, 960.0);
    final double canvasHeight =
        outerPad +
        (hasThumbs ? thumbHeight + gap : 0.0) +
        mainHeight +
        outerPad;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
    );

    // Background fill
    final bgPaint = Paint()..color = const Color(0xFF14161A);
    canvas.drawRect(Rect.fromLTWH(0, 0, canvasWidth, canvasHeight), bgPaint);

    final ageLabel = vehicle.shortAgeLabel(nowEpochMs: nowEpochMs);
    final badgeText = ageLabel.isNotEmpty ? ageLabel : 'Now';

    // 1. Draw secondary camera thumbnails in a row above the main view (true aspect ratio, never stretched)
    if (hasThumbs) {
      double cursorLeft = outerPad;
      for (int i = 0; i < thumbCount; i++) {
        final item = loadedThumbs[i];
        final thumbWidth = thumbHeight * thumbAspects[i];
        final rect = Rect.fromLTWH(
          cursorLeft,
          outerPad,
          thumbWidth,
          thumbHeight,
        );
        _drawRoundedImageFrame(
          canvas: canvas,
          rect: rect,
          image: item.image,
          radius: 8.0,
          bottomLeftLabel: item.label,
          topRightAgeMark: badgeText,
          isThumbnail: true,
        );
        cursorLeft += thumbWidth + gap;
      }
    }

    // 2. Draw main driver cam view below thumbnails
    final double mainTop = outerPad + (hasThumbs ? thumbHeight + gap : 0.0);
    final mainRect = Rect.fromLTWH(outerPad, mainTop, innerWidth, mainHeight);
    _drawRoundedImageFrame(
      canvas: canvas,
      rect: mainRect,
      image: mainImage,
      radius: 10.0,
      bottomLeftLabel: mainEntry.label,
      topRightAgeMark: badgeText,
      isThumbnail: false,
    );

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(
      canvasWidth.round(),
      canvasHeight.round(),
    );
    final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);

    // Dispose decoded images
    mainImage.dispose();
    for (final t in loadedThumbs) {
      t.image.dispose();
    }
    rendered.dispose();

    return byteData?.buffer.asUint8List();
  }

  static Future<ui.Image?> _decodeFileImage(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  static void _drawRoundedImageFrame({
    required Canvas canvas,
    required Rect rect,
    required ui.Image image,
    required double radius,
    required String bottomLeftLabel,
    required String topRightAgeMark,
    required bool isThumbnail,
  }) {
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    canvas.save();
    canvas.clipRRect(rrect);

    // Fill frame background
    canvas.drawRect(rect, Paint()..color = const Color(0xFF0A0C0E));

    // Contain-fit image inside rect so zero pixels are ever cropped or squished
    final srcSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, srcSize, rect.size);
    final srcRect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & srcSize,
    );
    final dstRect = Alignment.center.inscribe(fitted.destination, rect);
    canvas.drawImageRect(
      image,
      srcRect,
      dstRect,
      Paint()..filterQuality = FilterQuality.high,
    );

    canvas.restore();

    // Subtle border
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0xFF334155)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isThumbnail ? 1.5 : 2.0,
    );

    // Corner age mark in top-right (e.g., "Now", "2m", "5m")
    _drawBadgePill(
      canvas: canvas,
      text: topRightAgeMark,
      fontSize: isThumbnail ? 14.0 : 18.0,
      paddingH: isThumbnail ? 8.0 : 12.0,
      paddingV: isThumbnail ? 4.0 : 6.0,
      bgColor: const Color(0xD90F172A),
      borderColor: const Color(0xFF10B981),
      textColor: const Color(0xFF34D399),
      anchorTopRight: Offset(rect.right - 10, rect.top + 10),
    );

    // Subtle camera angle label in bottom-left
    _drawBadgePill(
      canvas: canvas,
      text: bottomLeftLabel,
      fontSize: isThumbnail ? 12.0 : 15.0,
      paddingH: isThumbnail ? 8.0 : 10.0,
      paddingV: isThumbnail ? 3.0 : 5.0,
      bgColor: const Color(0xCC0F172A),
      borderColor: const Color(0xFF475569),
      textColor: const Color(0xFFE2E8F0),
      anchorBottomLeft: Offset(rect.left + 10, rect.bottom - 10),
    );
  }

  static void _drawBadgePill({
    required Canvas canvas,
    required String text,
    required double fontSize,
    required double paddingH,
    required double paddingV,
    required Color bgColor,
    required Color borderColor,
    required Color textColor,
    Offset? anchorTopRight,
    Offset? anchorBottomLeft,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final pillW = tp.width + paddingH * 2;
    final pillH = tp.height + paddingV * 2;

    double left = 0;
    double top = 0;
    if (anchorTopRight != null) {
      left = anchorTopRight.dx - pillW;
      top = anchorTopRight.dy;
    } else if (anchorBottomLeft != null) {
      left = anchorBottomLeft.dx;
      top = anchorBottomLeft.dy - pillH;
    }

    final pillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, pillW, pillH),
      const Radius.circular(6),
    );
    canvas.drawRRect(pillRect, Paint()..color = bgColor);
    canvas.drawRRect(
      pillRect,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    tp.paint(canvas, Offset(left + paddingH, top + paddingV));
  }
}
