import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders interactive phone number chips for a driver or member.
///
/// - **Android / iOS**: Shows a split chip where tapping the phone icon/number
///   launches the native dialer (`tel:`), and tapping the copy icon copies the
///   number to the clipboard.
/// - **Desktop (Linux / Windows)**: Clicking anywhere on the chip copies the
///   phone number to the clipboard with an instant confirmation toast.
class PhoneChipsBar extends StatelessWidget {
  const PhoneChipsBar({
    super.key,
    required this.phones,
    this.compact = false,
  });

  final List<String> phones;
  final bool compact;

  bool get _isMobilePlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> _copyPhone(BuildContext context, String phone) async {
    await Clipboard.setData(ClipboardData(text: phone));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $phone to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _dialPhone(BuildContext context, String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final uri = Uri(scheme: 'tel', path: digits);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (context.mounted) {
      await _copyPhone(context, phone);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (phones.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: compact ? 4 : 6,
      runSpacing: compact ? 2 : 4,
      children: phones.map((phone) {
        if (_isMobilePlatform) {
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF14161A),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: const Color(0xFF33373F)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(5),
                  ),
                  onTap: () => _dialPhone(context, phone),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 4 : 7,
                      vertical: compact ? 1.5 : 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.phone_in_talk,
                          size: compact ? 10.5 : 12.5,
                          color: const Color(0xFF46A758),
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            phone,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact ? 10 : 11.5,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFFE8E8E8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: compact ? 14 : 17,
                  color: const Color(0xFF33373F),
                ),
                InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(5),
                  ),
                  onTap: () => _copyPhone(context, phone),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 4 : 6,
                      vertical: compact ? 1.5 : 3,
                    ),
                    child: Icon(
                      Icons.copy,
                      size: compact ? 10 : 11.5,
                      color: const Color(0xFF8B909C),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        // Desktop: single-click copies immediately
        return Tooltip(
          message: 'Click to copy $phone',
          child: InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: () => _copyPhone(context, phone),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 5 : 8,
                vertical: compact ? 1.5 : 3,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF14161A),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFF33373F)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.copy_rounded,
                    size: compact ? 10 : 11.5,
                    color: const Color(0xFFF5A623),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      phone,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 10 : 11.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFE8E8E8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
