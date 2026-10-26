import 'package:flutter/material.dart';
import '../../shell/view_models/app_shell_view_model.dart';

/// Dialog for signing in to Salesforce FSL and Motive accounts using:
/// 1. Standard Username/Email + Password login.
/// 2. 1-click Auto-Detect from an open browser (Chrome CDP port 9222).
/// 3. Optional Advanced Cookie/Token or `auth_state.json` paste (auto-resolving Org Name & ID).
class AuthSettingsDialog extends StatefulWidget {
  const AuthSettingsDialog({super.key, required this.viewModel});

  final AppShellViewModel viewModel;

  @override
  State<AuthSettingsDialog> createState() => _AuthSettingsDialogState();
}

class _AuthSettingsDialogState extends State<AuthSettingsDialog> {
  late final TextEditingController _fslBaseUrlCtrl;
  late final TextEditingController _fslUsernameCtrl;
  final TextEditingController _fslPasswordCtrl = TextEditingController();
  late final TextEditingController _fslCookieCtrl;

  final TextEditingController _motiveEmailCtrl = TextEditingController();
  final TextEditingController _motivePasswordCtrl = TextEditingController();
  final TextEditingController _motiveOrgNameCtrl = TextEditingController();
  final TextEditingController _motiveTokenCtrl = TextEditingController();

  bool _isBusy = false;
  String? _statusMessage;
  bool _isError = false;
  bool _obscureFslPassword = true;
  bool _obscureMotivePassword = true;

  @override
  void initState() {
    super.initState();
    final auth = widget.viewModel.authService;
    _fslBaseUrlCtrl = TextEditingController(text: auth.fslBaseUrl);
    _fslUsernameCtrl = TextEditingController(text: auth.fslSavedUsername);
    _fslCookieCtrl = TextEditingController(text: auth.fslCookieHeader);
    _motiveEmailCtrl.text = auth.motiveSavedEmail;
  }

  @override
  void dispose() {
    _fslBaseUrlCtrl.dispose();
    _fslUsernameCtrl.dispose();
    _fslPasswordCtrl.dispose();
    _fslCookieCtrl.dispose();
    _motiveEmailCtrl.dispose();
    _motivePasswordCtrl.dispose();
    _motiveOrgNameCtrl.dispose();
    _motiveTokenCtrl.dispose();
    super.dispose();
  }

  void _setFeedback(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _isError = isError;
    });
  }

  Future<void> _autoSyncFromBrowser() async {
    setState(() {
      _isBusy = true;
      _statusMessage = null;
    });
    try {
      final msg = await widget.viewModel.syncSessionsFromBrowser();
      _fslCookieCtrl.text = widget.viewModel.authService.fslCookieHeader;
      _setFeedback(msg, isError: msg.startsWith('No '));
    } catch (e) {
      _setFeedback('Browser sync failed: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _launchBrowserForSignIn() async {
    await widget.viewModel.authService.launchBrowserForLogin();
    _setFeedback(
      'Opened browser window. Log in with "Remember me" checked, then click "Auto-Detect from Open Browser".',
    );
  }

  Future<void> _loginFslWithPassword() async {
    setState(() {
      _isBusy = true;
      _statusMessage = null;
    });
    try {
      await widget.viewModel.authService.loginFslWithCredentials(
        username: _fslUsernameCtrl.text,
        password: _fslPasswordCtrl.text,
        baseUrl: _fslBaseUrlCtrl.text,
      );
      _fslCookieCtrl.text = widget.viewModel.authService.fslCookieHeader;
      _fslPasswordCtrl.clear();
      _setFeedback('Signed in to Salesforce FSL successfully.');
      await widget.viewModel.pollFslNow(fullShiftReload: true);
    } catch (e) {
      _setFeedback(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _loginMotiveWithPassword() async {
    setState(() {
      _isBusy = true;
      _statusMessage = null;
    });
    try {
      final session = await widget.viewModel.authService
          .loginMotiveWithCredentials(
            email: _motiveEmailCtrl.text,
            password: _motivePasswordCtrl.text,
            customOrgName: _motiveOrgNameCtrl.text,
          );
      _motivePasswordCtrl.clear();
      _setFeedback(
        'Signed in to Motive (${session.organizationName}) successfully.',
      );
      await widget.viewModel.syncMotiveFleet();
    } catch (e) {
      _setFeedback(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _saveFslRawCookie() async {
    await widget.viewModel.authService.saveFslSession(
      cookieHeader: _fslCookieCtrl.text,
      baseUrl: _fslBaseUrlCtrl.text,
    );
    _setFeedback('Saved Salesforce FSL session cookie.');
    await widget.viewModel.pollFslNow(fullShiftReload: true);
  }

  Future<void> _addMotiveRawToken() async {
    final token = _motiveTokenCtrl.text.trim();
    if (token.isEmpty) return;

    setState(() => _isBusy = true);
    try {
      final session = await widget.viewModel.authService
          .validateAndAddMotiveToken(
            rawTokenInput: token,
            customOrgName: _motiveOrgNameCtrl.text,
          );
      _motiveOrgNameCtrl.clear();
      _motiveTokenCtrl.clear();
      _setFeedback('Added Motive organization: ${session.organizationName}.');
      await widget.viewModel.syncMotiveFleet();
    } catch (e) {
      _setFeedback('Failed to add Motive token: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = widget.viewModel.authService;
    final accounts = auth.motiveAccounts;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.hub_outlined, size: 22, color: Color(0xFF38BDF8)),
          SizedBox(width: 10),
          Text('Connections & Accounts'),
        ],
      ),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. One-click Browser Session Sync Card
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.sync_rounded,
                          size: 18,
                          color: Color(0xFF38BDF8),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Instant Browser Sync (Recommended on Desktop)',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Automatically grabs your active Salesforce FSL and Motive sessions from an open Chrome window (including 2FA & Remember Me sessions) — no tokens needed.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _isBusy ? null : _autoSyncFromBrowser,
                          icon: const Icon(Icons.bolt, size: 16),
                          label: const Text('Auto-Detect from Open Browser'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _isBusy ? null : _launchBrowserForSignIn,
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('Open Login Tabs in Browser'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              if (_statusMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _isError
                        ? const Color(0xFF451A1A)
                        : const Color(0xFF064E3B),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _isError
                          ? const Color(0xFFEF4444)
                          : const Color(0xFF10B981),
                    ),
                  ),
                  child: Text(
                    _statusMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _isError
                          ? const Color(0xFFFCA5A5)
                          : const Color(0xFFA7F3D0),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 18),

              // 2. Salesforce FSL Standard Login
              Row(
                children: [
                  const Text(
                    'Salesforce Field Service (FSL)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(isConnected: auth.hasFslSession),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fslUsernameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Salesforce Username',
                        hintText: 'user@example.com',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _fslPasswordCtrl,
                      obscureText: _obscureFslPassword,
                      onSubmitted: (_) => _loginFslWithPassword(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        isDense: true,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureFslPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 16,
                          ),
                          onPressed: () => setState(
                            () => _obscureFslPassword = !_obscureFslPassword,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _isBusy ? null : _loginFslWithPassword,
                    child: const Text('Sign In'),
                  ),
                ],
              ),

              const Divider(height: 28),

              // 3. Motive Organizations Standard Login
              Row(
                children: [
                  const Text(
                    'Motive Organizations',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(
                    isConnected: auth.hasMotiveSession,
                    connectedText: '${accounts.length} Connected',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (accounts.isEmpty)
                const Text(
                  'No Motive accounts connected yet.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                )
              else
                ...accounts.map(
                  (a) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: Color(0xFF10B981),
                    ),
                    title: Text(
                      a.organizationId.isNotEmpty
                          ? '${a.organizationName} (ID: ${a.organizationId})'
                          : a.organizationName,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Remove account',
                      onPressed: () async {
                        await auth.removeMotiveAccount(a);
                        setState(() {});
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _motiveEmailCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Motive Email',
                        hintText: 'fleet@example.com',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _motivePasswordCtrl,
                      obscureText: _obscureMotivePassword,
                      onSubmitted: (_) => _loginMotiveWithPassword(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        isDense: true,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureMotivePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 16,
                          ),
                          onPressed: () => setState(
                            () =>
                                _obscureMotivePassword = !_obscureMotivePassword,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _isBusy ? null : _loginMotiveWithPassword,
                    child: const Text('Sign In'),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 4. Collapsible Advanced Token / Cookie Import
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'Advanced: Manual Session Cookie / Token or auth_state.json',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
                children: [
                  const SizedBox(height: 6),
                  TextField(
                    controller: _fslBaseUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'FSL Community Base URL',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _fslCookieCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'FSL Session Cookie (sid=...) or auth_state.json',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _isBusy ? null : _saveFslRawCookie,
                        child: const Text('Save Cookie'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _motiveTokenCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Motive auth_token or auth_state.json (Org Name auto-detected)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _isBusy ? null : _addMotiveRawToken,
                        child: const Text('Add Token'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.isConnected,
    this.connectedText = 'Connected',
  });

  final bool isConnected;
  final String connectedText;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isConnected
            ? const Color(0xFF064E3B)
            : const Color(0xFF334155),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isConnected ? connectedText : 'Not Connected',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isConnected
              ? const Color(0xFF34D399)
              : const Color(0xFF94A3B8),
        ),
      ),
    );
  }
}
