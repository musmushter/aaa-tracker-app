import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../domain/models/motive_vehicle.dart';
import '../../domain/use_cases/motive_report_builder.dart';

final class _GtkTargetEntry extends ffi.Struct {
  external ffi.Pointer<ffi.Uint8> target;

  @ffi.Uint32()
  external int flags;

  @ffi.Uint32()
  external int info;
}

typedef _CallocNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.IntPtr num,
  ffi.IntPtr size,
);
typedef _CallocDart = ffi.Pointer<ffi.Uint8> Function(int num, int size);

typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Void> ptr);

typedef _GdkAtomInternNative = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Uint8> atomName,
);
typedef _GdkAtomInternDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Uint8> atomName,
);

typedef _GtkClipboardGetNative = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Void> selectionAtom,
);
typedef _GtkClipboardGetDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Void> selectionAtom,
);

typedef _GtkClipboardSetTextNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<ffi.Uint8> text,
  ffi.Int32 len,
);
typedef _GtkClipboardSetTextDart = void Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<ffi.Uint8> text,
  int len,
);

typedef _GdkPixbufNewFromFileNative = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Uint8> filename,
  ffi.Pointer<ffi.Pointer<ffi.Void>> error,
);
typedef _GdkPixbufNewFromFileDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Uint8> filename,
  ffi.Pointer<ffi.Pointer<ffi.Void>> error,
);

typedef _GtkClipboardSetImageNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<ffi.Void> pixbuf,
);
typedef _GtkClipboardSetImageDart = void Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<ffi.Void> pixbuf,
);

typedef _GtkClipboardGetFuncNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<ffi.Void> selectionData,
  ffi.Uint32 info,
  ffi.Pointer<ffi.Void> userData,
);

typedef _GtkClipboardClearFuncNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<ffi.Void> userData,
);

typedef _GtkClipboardSetWithDataNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<_GtkTargetEntry> targets,
  ffi.Uint32 nTargets,
  ffi.Pointer<ffi.NativeFunction<_GtkClipboardGetFuncNative>> getFunc,
  ffi.Pointer<ffi.NativeFunction<_GtkClipboardClearFuncNative>> clearFunc,
  ffi.Pointer<ffi.Void> userData,
);
typedef _GtkClipboardSetWithDataDart = int Function(
  ffi.Pointer<ffi.Void> clipboard,
  ffi.Pointer<_GtkTargetEntry> targets,
  int nTargets,
  ffi.Pointer<ffi.NativeFunction<_GtkClipboardGetFuncNative>> getFunc,
  ffi.Pointer<ffi.NativeFunction<_GtkClipboardClearFuncNative>> clearFunc,
  ffi.Pointer<ffi.Void> userData,
);

typedef _GtkSelectionDataSetPixbufNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> selectionData,
  ffi.Pointer<ffi.Void> pixbuf,
);
typedef _GtkSelectionDataSetPixbufDart = void Function(
  ffi.Pointer<ffi.Void> selectionData,
  ffi.Pointer<ffi.Void> pixbuf,
);

typedef _GObjectUnrefNative = ffi.Void Function(ffi.Pointer<ffi.Void> object);
typedef _GObjectUnrefDart = void Function(ffi.Pointer<ffi.Void> object);

class MotiveReportActionResult {
  const MotiveReportActionResult({
    required this.reportText,
    required this.hasStitchedImage,
    required this.sharedViaNativeSheet,
    required this.copiedImageToClipboard,
    this.stitchedFilePath,
  });

  final String reportText;
  final bool hasStitchedImage;
  final bool sharedViaNativeSheet;
  final bool copiedImageToClipboard;
  final String? stitchedFilePath;
}

/// Executes a single-button camera report action across Android, Linux, and Windows.
///
/// - Renders the stitched camera collage (`driver` cam as main hero view, any
///   other available camera angles as small thumbnails above it, and the corner
///   age badge `Now`, `2m`, `5m`, etc.).
/// - Generates the clean report text (`Driver: <Name>\n<Live URL>` or `<Live URL>`).
/// - On Android/iOS: opens the native system share sheet with both the stitched
///   PNG file and the text caption attached in a single tap.
/// - On Linux/Windows:
///   1. Copies the stitched PNG to `CLIPBOARD` (`Ctrl+V` #1 pastes the image into
///      WhatsApp, which opens the media preview and focuses the caption box).
///   2. Automatically switches `CLIPBOARD` to the `Driver + URL` text right after
///      the image is pasted so pressing `Ctrl+V` #2 (or Middle-Click on Linux)
///      pastes the caption directly into WhatsApp's caption box!
class MotiveReportShareService {
  static ffi.Pointer<ffi.Void> _activePixbuf = ffi.nullptr;
  static _GtkSelectionDataSetPixbufDart? _gtkSelectionDataSetPixbuf;
  static int _lastCopyEpochMs = 0;
  static String _pendingCaptionText = '';
  static bool _hasScheduledTextFlip = false;
  static ffi.NativeCallable<_GtkClipboardGetFuncNative>? _getCallable;
  static ffi.NativeCallable<_GtkClipboardClearFuncNative>? _clearCallable;
  static Process? _winClipboardWatcherProc;

  static Future<MotiveReportActionResult> executeSingleButtonReport(
    MotiveVehicle vehicle, {
    Future<MotiveVehicle?> Function(String vehicleId)? onEnsureSnapshots,
  }) async {
    MotiveVehicle targetVehicle = vehicle;

    // 1. Always push reportText to system clipboard first (populates clipboard history)
    var reportText = MotiveReportBuilder.buildSimpleReportText(targetVehicle);
    await Clipboard.setData(ClipboardData(text: reportText));

    // 2. Render stitched camera collage; if no snapshots exist on disk yet,
    //    auto-refresh the vehicle's cameras first if a callback was provided.
    var pngBytes = await MotiveReportBuilder.renderStitchedCameraPng(
      targetVehicle,
    );
    if ((pngBytes == null || pngBytes.isEmpty) && onEnsureSnapshots != null) {
      final refreshed = await onEnsureSnapshots(targetVehicle.id);
      if (refreshed != null) {
        targetVehicle = refreshed;
        reportText = MotiveReportBuilder.buildSimpleReportText(targetVehicle);
        await Clipboard.setData(ClipboardData(text: reportText));
        pngBytes = await MotiveReportBuilder.renderStitchedCameraPng(
          targetVehicle,
        );
      }
    }

    String? stitchedPath;

    if (pngBytes != null && pngBytes.isNotEmpty) {
      final baseDir = await getApplicationSupportDirectory();
      final outDir = Directory(p.join(baseDir.path, 'snapshots'));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final safeId = targetVehicle.id.replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '_',
      );
      stitchedPath = p.join(outDir.path, '${safeId}_stitched.png');
      await File(stitchedPath).writeAsBytes(pngBytes, flush: true);
    }

    // 3. Mobile (Android / iOS): Native share sheet with stitched image + text
    if (Platform.isAndroid || Platform.isIOS) {
      if (stitchedPath != null) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(stitchedPath, mimeType: 'image/png')],
            text: reportText,
          ),
        );
      } else {
        await SharePlus.instance.share(ShareParams(text: reportText));
      }
      return MotiveReportActionResult(
        reportText: reportText,
        hasStitchedImage: stitchedPath != null,
        sharedViaNativeSheet: true,
        copiedImageToClipboard: false,
        stitchedFilePath: stitchedPath,
      );
    }

    // 4. Desktop (Linux / Windows / macOS): Copy stitched PNG to system clipboard
    //    with automatic post-paste switch to reportText for WhatsApp caption pasting
    bool copiedImage = false;
    if (stitchedPath != null) {
      if (Platform.isLinux) {
        copiedImage = await _copyToLinuxClipboard(
          stitchedPath: stitchedPath,
          reportText: reportText,
        );
      } else if (Platform.isWindows) {
        copiedImage = await _copyToWindowsClipboard(
          stitchedPath: stitchedPath,
          reportText: reportText,
        );
      }
    }

    return MotiveReportActionResult(
      reportText: reportText,
      hasStitchedImage: stitchedPath != null,
      sharedViaNativeSheet: false,
      copiedImageToClipboard: copiedImage,
      stitchedFilePath: stitchedPath,
    );
  }

  static Future<bool> _copyToLinuxClipboard({
    required String stitchedPath,
    required String reportText,
  }) async {
    // Also push reportText into KDE Klipper history if running on KDE Plasma
    try {
      await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.kde.klipper',
        '--object-path',
        '/klipper',
        '--method',
        'org.kde.klipper.klipper.setClipboardContents',
        reportText,
      ]).timeout(const Duration(milliseconds: 500));
    } catch (_) {}

    // Give desktop clipboard managers ~120ms to index the text entry before setting image/png
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // 1. Primary path: In-process GTK3 + GdkPixbuf clipboard with auto-caption transition
    if (_copyViaGtk3Ffi(stitchedPath: stitchedPath, reportText: reportText)) {
      return true;
    }

    // 2. Fallback: Place reportText in X11/Wayland primary selection via CLI if available
    try {
      final primaryProc = await Process.start('xclip', [
        '-selection',
        'primary',
      ]);
      primaryProc.stdin.add(utf8.encode(reportText));
      await primaryProc.stdin.close();
      await primaryProc.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      try {
        final wlPrimary = await Process.start('wl-copy', ['--primary']);
        wlPrimary.stdin.add(utf8.encode(reportText));
        await wlPrimary.stdin.close();
        await wlPrimary.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    // Try xclip for image/png
    try {
      final res = await Process.run('xclip', [
        '-selection',
        'clipboard',
        '-t',
        'image/png',
        '-i',
        stitchedPath,
      ]).timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) return true;
    } catch (_) {}

    // Fallback to wl-copy on pure Wayland
    try {
      final wlProc = await Process.start('wl-copy', ['--type', 'image/png']);
      final bytes = await File(stitchedPath).readAsBytes();
      wlProc.stdin.add(bytes);
      await wlProc.stdin.close();
      final code = await wlProc.exitCode.timeout(const Duration(seconds: 3));
      if (code == 0) return true;
    } catch (_) {}

    return false;
  }

  static void _onGtkClipboardGet(
    ffi.Pointer<ffi.Void> clipboard,
    ffi.Pointer<ffi.Void> selectionData,
    int info,
    ffi.Pointer<ffi.Void> userData,
  ) {
    final elapsed = DateTime.now().millisecondsSinceEpoch - _lastCopyEpochMs;
    // Ignore the immediate (< 180ms) probe from KDE Klipper / Wayland clipboard
    // managers when gtk_clipboard_set_with_data is first called. If we return the
    // pixbuf on that t=2ms probe, Klipper caches the image and takes over
    // clipboard ownership, preventing us from detecting the user's first Ctrl+V!
    if (elapsed < 180) {
      return;
    }

    if (_activePixbuf != ffi.nullptr && _gtkSelectionDataSetPixbuf != null) {
      _gtkSelectionDataSetPixbuf!(selectionData, _activePixbuf);
    }

    // When an external app (e.g. WhatsApp in Chrome) requests the image via Ctrl+V
    // (>= 180ms after we set the clipboard), serve the stitched PNG for this paste
    // and then switch the clipboard to the Driver + URL caption text 220ms later
    // so the user's next Ctrl+V in WhatsApp's caption box pastes the text!
    if (!_hasScheduledTextFlip && _pendingCaptionText.isNotEmpty) {
      _hasScheduledTextFlip = true;
      final textToSet = _pendingCaptionText;
      Timer(const Duration(milliseconds: 220), () {
        unawaited(_promoteTextToLinuxClipboard(textToSet));
      });
    }
  }

  static void _onGtkClipboardClear(
    ffi.Pointer<ffi.Void> clipboard,
    ffi.Pointer<ffi.Void> userData,
  ) {}

  static Future<void> _promoteTextToLinuxClipboard(String text) async {
    try {
      await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.kde.klipper',
        '--object-path',
        '/klipper',
        '--method',
        'org.kde.klipper.klipper.clearClipboardContents',
      ]).timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    try {
      await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.kde.klipper',
        '--object-path',
        '/klipper',
        '--method',
        'org.kde.klipper.klipper.setClipboardContents',
        text,
      ]).timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {}
  }

  /// Sets the stitched PNG image onto the GTK3 `CLIPBOARD` selection using
  /// `gtk_clipboard_set_with_data` (so we detect when the image is pasted into
  /// WhatsApp and auto-advance the clipboard to [reportText]) and sets
  /// [reportText] onto the `PRIMARY` selection (middle-click paste).
  static bool _copyViaGtk3Ffi({
    required String stitchedPath,
    required String reportText,
  }) {
    try {
      final procLib = ffi.DynamicLibrary.process();
      final gtkLib = ffi.DynamicLibrary.open('libgtk-3.so.0');
      final pixbufLib = ffi.DynamicLibrary.open('libgdk_pixbuf-2.0.so.0');
      final gobjLib = ffi.DynamicLibrary.open('libgobject-2.0.so.0');

      final calloc = procLib.lookupFunction<_CallocNative, _CallocDart>(
        'calloc',
      );
      final free = procLib.lookupFunction<_FreeNative, _FreeDart>('free');
      final gdkAtomIntern = gtkLib
          .lookupFunction<_GdkAtomInternNative, _GdkAtomInternDart>(
            'gdk_atom_intern_static_string',
          );
      final gtkClipboardGet = gtkLib
          .lookupFunction<_GtkClipboardGetNative, _GtkClipboardGetDart>(
            'gtk_clipboard_get',
          );
      final gtkClipboardSetText = gtkLib
          .lookupFunction<_GtkClipboardSetTextNative, _GtkClipboardSetTextDart>(
            'gtk_clipboard_set_text',
          );
      final gtkClipboardSetImage = gtkLib.lookupFunction<
        _GtkClipboardSetImageNative,
        _GtkClipboardSetImageDart
      >('gtk_clipboard_set_image');
      final gtkClipboardSetWithData = gtkLib.lookupFunction<
        _GtkClipboardSetWithDataNative,
        _GtkClipboardSetWithDataDart
      >('gtk_clipboard_set_with_data');
      final gtkSelectionDataSetPixbuf = gtkLib.lookupFunction<
        _GtkSelectionDataSetPixbufNative,
        _GtkSelectionDataSetPixbufDart
      >('gtk_selection_data_set_pixbuf');
      final gdkPixbufNewFromFile = pixbufLib.lookupFunction<
        _GdkPixbufNewFromFileNative,
        _GdkPixbufNewFromFileDart
      >('gdk_pixbuf_new_from_file');
      final gObjectUnref = gobjLib
          .lookupFunction<_GObjectUnrefNative, _GObjectUnrefDart>(
            'g_object_unref',
          );

      _gtkSelectionDataSetPixbuf = gtkSelectionDataSetPixbuf;

      ffi.Pointer<ffi.Uint8> allocCString(String s) {
        final bytes = utf8.encode(s);
        final ptr = calloc(bytes.length + 1, 1);
        ptr.asTypedList(bytes.length).setAll(0, bytes);
        ptr[bytes.length] = 0;
        return ptr;
      }

      // 1. Set PRIMARY selection to reportText (middle-click paste)
      final primaryStr = allocCString('PRIMARY');
      final textStr = allocCString(reportText);
      try {
        final primaryAtom = gdkAtomIntern(primaryStr);
        final primaryClipboard = gtkClipboardGet(primaryAtom);
        if (primaryClipboard != ffi.nullptr) {
          gtkClipboardSetText(primaryClipboard, textStr, -1);
        }
      } finally {
        free(primaryStr.cast());
        free(textStr.cast());
      }

      // 2. Load stitched PNG into GdkPixbuf and register CLIPBOARD with get callback
      final clipboardStr = allocCString('CLIPBOARD');
      final pathStr = allocCString(stitchedPath);
      final mimePng = allocCString('image/png');
      final mimeBmp = allocCString('image/bmp');
      final mimeJpeg = allocCString('image/jpeg');
      final targetsPtr = calloc(
        3,
        ffi.sizeOf<_GtkTargetEntry>(),
      ).cast<_GtkTargetEntry>();

      try {
        final clipboardAtom = gdkAtomIntern(clipboardStr);
        final clipboard = gtkClipboardGet(clipboardAtom);
        if (clipboard == ffi.nullptr) return false;

        final pixbuf = gdkPixbufNewFromFile(pathStr, ffi.nullptr);
        if (pixbuf == ffi.nullptr) return false;

        if (_activePixbuf != ffi.nullptr) {
          gObjectUnref(_activePixbuf);
        }
        _activePixbuf = pixbuf;
        _lastCopyEpochMs = DateTime.now().millisecondsSinceEpoch;
        _pendingCaptionText = reportText;
        _hasScheduledTextFlip = false;

        _getCallable ??=
            ffi.NativeCallable<_GtkClipboardGetFuncNative>.isolateLocal(
              _onGtkClipboardGet,
            );
        _clearCallable ??=
            ffi.NativeCallable<_GtkClipboardClearFuncNative>.isolateLocal(
              _onGtkClipboardClear,
            );

        targetsPtr[0]
          ..target = mimePng
          ..flags = 0
          ..info = 1;
        targetsPtr[1]
          ..target = mimeBmp
          ..flags = 0
          ..info = 1;
        targetsPtr[2]
          ..target = mimeJpeg
          ..flags = 0
          ..info = 1;

        final ok = gtkClipboardSetWithData(
          clipboard,
          targetsPtr,
          3,
          _getCallable!.nativeFunction,
          _clearCallable!.nativeFunction,
          ffi.nullptr,
        );
        if (ok == 0) {
          // Fallback to direct gtk_clipboard_set_image if set_with_data failed
          gtkClipboardSetImage(clipboard, pixbuf);
        }
        // NOTE: Do NOT call gtkClipboardStore(clipboard) here, as that immediately
        // serializes the image into the clipboard manager and bypasses _onGtkClipboardGet!
        return true;
      } finally {
        free(targetsPtr.cast());
        free(mimePng.cast());
        free(mimeBmp.cast());
        free(mimeJpeg.cast());
        free(clipboardStr.cast());
        free(pathStr.cast());
      }
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _copyToWindowsClipboard({
    required String stitchedPath,
    required String reportText,
  }) async {
    try {
      _winClipboardWatcherProc?.kill();
      _winClipboardWatcherProc = null;

      // Give Win+V clipboard history ~150ms to register the text entry first
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final escapedPath = stitchedPath.replaceAll("'", "''");
      final escapedText = reportText.replaceAll("'", "''");

      // 1. Set both Image and Text onto the Windows Clipboard DataObject immediately
      final setScript =
          "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
          "\$img = [System.Drawing.Image]::FromFile('$escapedPath'); "
          "\$do = New-Object System.Windows.Forms.DataObject; "
          "\$do.SetImage(\$img); "
          "\$do.SetText('$escapedText'); "
          "[System.Windows.Forms.Clipboard]::SetDataObject(\$do, \$true); "
          "\$img.Dispose();";
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Sta',
        '-Command',
        setScript,
      ]).timeout(const Duration(seconds: 5));

      // 2. Spawn a lightweight 20-second watcher that detects the user's first Ctrl+V
      //    (which pastes the image into WhatsApp) and switches the clipboard to
      //    reportText 300ms later so their second Ctrl+V pastes the caption!
      final watchScript =
          "Add-Type -AssemblyName System.Windows.Forms; "
          "\$sig = '[DllImport(\"user32.dll\")] public static extern short GetAsyncKeyState(int vKey);'; "
          "\$u = Add-Type -MemberDefinition \$sig -Name 'Win32Key' -Namespace 'Win32' -PassThru; "
          "Start-Sleep -Milliseconds 400; "
          "for (\$i = 0; \$i -lt 400; \$i++) { "
          "  Start-Sleep -Milliseconds 50; "
          "  if ((\$u::GetAsyncKeyState(0x11) -band 0x8000) -and (\$u::GetAsyncKeyState(0x56) -band 0x8000)) { "
          "    Start-Sleep -Milliseconds 300; "
          "    [System.Windows.Forms.Clipboard]::SetText('$escapedText'); "
          "    break; "
          "  } "
          "}";
      _winClipboardWatcherProc = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Sta',
        '-Command',
        watchScript,
      ]);

      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
