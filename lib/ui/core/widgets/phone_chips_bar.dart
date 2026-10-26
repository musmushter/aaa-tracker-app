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
      spacing: 6,
      runSpacing: 4,
      children: phones.map((phone) {
        if (_isMobilePlatform) {
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                  onTap: () => _dialPhone(context, phone),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 6 : 8,
                      vertical: compact ? 3 : 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.phone_in_talk,
                          size: 13,
                          color: Color(0xFF10B981),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            phone,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compact ? 11 : 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 18,
                  color: const Color(0xFF334155),
                ),
                InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(8),
                  ),
                  onTap: () => _copyPhone(context, phone),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 5 : 6,
                      vertical: compact ? 3 : 4,
                    ),
                    child: const Icon(
                      Icons.copy,
                      size: 12,
                      color: Color(0xFF94A3B8),
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
            borderRadius: BorderRadius.circular(8),
            onTap: () => _copyPhone(context, phone),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 7 : 9,
                vertical: compact ? 3 : 4,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.copy_rounded,
                    size: 12,
                    color: Color(0xFFF59E0B),
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      phone,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFE2E8F0),
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
