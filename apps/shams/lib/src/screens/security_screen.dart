import 'package:flutter/material.dart';
// Already resolved through gpt_markdown; no new dependency is installed.
// ignore: depend_on_referenced_packages
import 'package:flutter_svg/flutter_svg.dart';

import '../api/models.dart';
import '../api/shams_api.dart';

/// The account & security screen: the same surface the web panel draws, from
/// the same endpoints.
///
/// Every state on this screen is the server's, never inferred — two-factor is
/// offered because the account does not have it, a cooldown is worded from the
/// wait the server reported, and a code the client has not been given is
/// assumed not to exist. Nothing here decides whether a sign-in is allowed;
/// `POST /api/v1/sessions` does that.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({required this.api, super.key});

  final ShamsApi api;

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _password = TextEditingController();
  final _factorCode = TextEditingController();
  final _factorForm = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _code = TextEditingController();

  SecurityPanel? _panel;
  String? _error;
  bool _busy = false;

  /// The pending key this client was handed, until it is proved or abandoned.
  /// A refresh does not carry one — the server only ever sends it in the
  /// response that minted it — so the step lives here rather than in [_panel].
  TwoFactorEnrollment? _enrollment;

  /// Backup codes this client was handed. They exist in no later response, so
  /// this screen keeps the only copy until the user dismisses it.
  List<String> _codes = const [];

  /// A code was sent to the number, so the verify step is offered. Display
  /// state only — the server holds the real pending record.
  bool _phoneCodeSent = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _password.dispose();
    _factorCode.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _refresh() => _run(widget.api.security);

  Future<SecurityPanel?> _run(Future<SecurityPanel> Function() action) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final panel = await action();
      if (!mounted) return panel;
      setState(() {
        // A call that ended this session carries no state to draw - it answers
        // with a message and nothing else. Redrawing that as an empty panel
        // would say "two-factor off, no devices", which was never the truth.
        if (!panel.signedOut) _apply(panel);
      });
      return panel;
    } on ApiException catch (error) {
      if (!mounted) return null;
      _report(error);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Where a refusal is shown.
  ///
  /// An action that fails halfway down this list must not answer from the top
  /// of it, so a loaded screen reports in a snack bar and the full-page notice
  /// is reserved for a panel that never arrived. The wait, when the server gave
  /// one, is its number and not a countdown started here.
  void _report(ApiException error) {
    final text = error.unauthorized
        ? 'Your session has ended. Sign in again.'
        : error.message;
    final words = error.retryInSeconds == null
        ? text
        : '$text Try again in ${error.retryInSeconds} seconds.';

    if (_panel == null) {
      setState(() => _error = words);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(words),
        showCloseIcon: true,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _apply(SecurityPanel panel) {
    _panel = panel;
    if (panel.recoveryCodes.isNotEmpty) _codes = panel.recoveryCodes;
    if (panel.enrollment != null) _enrollment = panel.enrollment;
    // Activation is the server's answer, not this screen's guess.
    if (panel.twoFactorEnabled && _enrollment != null) {
      _enrollment = null;
      _code.clear();
    }
    // The number the account already has, so re-sending a code does not mean
    // retyping it. An empty field is the only one this fills.
    if (_phone.text.isEmpty && panel.phone.number.isNotEmpty) {
      _phone.text = panel.phone.number;
    }
  }

  Future<void> _changeTwoFactor({required bool disable}) async {
    if (_busy || _codes.isNotEmpty) return;
    if (!(_factorForm.currentState?.validate() ?? false)) return;
    try {
      await _run(
        () => disable
            ? widget.api.disableTwoFactor(
                _password.text,
                code: _factorCode.text.trim(),
              )
            : widget.api.regenerateRecoveryCodes(
                _password.text,
                code: _factorCode.text.trim(),
              ),
      );
    } finally {
      // Do not retain a password or a possibly spent single-use code.
      if (mounted) {
        _password.clear();
        _factorCode.clear();
      }
    }
  }

  void _remindToSaveCodes() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Save your backup codes, then select “I have saved them” '
            'before leaving.'),
      ),
    );
  }

  Future<void> _cancelEnrollment() async {
    setState(() {
      _enrollment = null;
      _code.clear();
    });
    // The pending key stays in the server's session until it expires on its
    // own; abandoning this step has not changed the account.
    await _refresh();
  }

  Future<void> _sendPhoneCode() async {
    final panel = await _run(
      () => widget.api.requestPhoneCode(_phone.text.trim()),
    );
    if (!mounted) return;
    // Offer the verify step only for as long as the server said a code went out.
    setState(() => _phoneCodeSent = panel?.outcome == 'sent');
  }

  Future<void> _verifyPhoneCode() async {
    final panel = await _run(
      () => widget.api.confirmPhoneCode(_code.text.trim()),
    );
    if (!mounted) return;
    if (panel?.phone.verified ?? false) {
      setState(() {
        _phoneCodeSent = false;
        _code.clear();
      });
    }
  }

  Future<void> _revoke(DeviceSession device) async {
    if (_codes.isNotEmpty) return;
    final panel = await _run(() => widget.api.revokeDevice(device.id));
    if (!mounted) return;
    // Revoking the row this client is signed in on ends this session, which is
    // what the screen is for when the device is lost.
    if (panel?.signedOut ?? false) Navigator.of(context).pop();
  }

  Future<void> _signOutEverywhere() async {
    if (_busy || _codes.isNotEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.signOutEverywhere();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _report(error);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final panel = _panel;
    return PopScope<Object?>(
      // Also protect the gap while a response may be minting one-time codes.
      canPop: !_busy && _codes.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _codes.isNotEmpty) _remindToSaveCodes();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Account & security')),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              if (_error != null) _Problem(message: _error!),
              if (panel == null)
                if (_error != null)
                  const SizedBox(height: 8)
                else
                  const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
              else ...[
                if (_codes.isNotEmpty) ...[
                  _backupCodes(),
                  const SizedBox(height: 24),
                ],
                _twoFactor(panel),
                const SizedBox(height: 24),
                _phoneSection(panel),
                const SizedBox(height: 24),
                _devices(panel),
                const SizedBox(height: 24),
                _usage(panel),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _twoFactor(SecurityPanel panel) {
    final theme = Theme.of(context);
    final enrollment = _enrollment;

    return _Section(
      title: 'Two-factor authentication',
      trailing: _State(
        label: panel.twoFactorEnabled ? 'On' : 'Off',
        positive: panel.twoFactorEnabled,
      ),
      children: [
        Text(
          panel.twoFactorEnabled
              ? 'Sign-ins need a six-digit code from your authenticator app, or '
                    'one of your ${panel.recoveryCodesLeft} backup '
                    '${panel.recoveryCodesLeft == 1 ? "code" : "codes"}. The key '
                    'itself is stored encrypted and is never shown again.'
              : 'Require a code from Google Authenticator, Microsoft '
                    'Authenticator, Aegis or any other TOTP app after your '
                    'password. Your password alone stops being enough.',
          style: theme.textTheme.bodyMedium,
        ),
        if (panel.lockedMinutesLeft > 0) ...[
          const SizedBox(height: 8),
          Text(
            'Too many wrong codes. Sign-ins with a code are paused for '
            '${panel.lockedMinutesLeft} more '
            '${panel.lockedMinutesLeft == 1 ? "minute" : "minutes"}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (enrollment != null)
          _Enrollment(
            enrollment: enrollment,
            busy: _busy,
            controller: _code,
            onActivate: () =>
                _run(() => widget.api.confirmTwoFactor(_code.text.trim())),
            onCancel: _cancelEnrollment,
          )
        else if (panel.twoFactorEnabled)
          Form(
            key: _factorForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Confirm changes with your current password and a six-digit '
                  'authenticator code or one unused backup code. Generating a '
                  'new set invalidates the old codes; turning two-factor off '
                  'removes this protection.',
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _password,
                  enabled: !_busy && _codes.isEmpty,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.password],
                  validator: (value) => value == null || value.isEmpty
                      ? 'Enter your current password.'
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Current password',
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _factorCode,
                  enabled: !_busy && _codes.isEmpty,
                  keyboardType: TextInputType.text,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter an authenticator or backup code.'
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Authenticator or backup code',
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _busy || _codes.isNotEmpty
                      ? null
                      : () => _changeTwoFactor(disable: false),
                  child: const Text('Generate new backup codes'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy || _codes.isNotEmpty
                      ? null
                      : () => _changeTwoFactor(disable: true),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Turn two-factor off'),
                ),
              ],
            ),
          )
        else
          FilledButton(
            onPressed: _busy ? null : () => _run(widget.api.startTwoFactor),
            child: const Text('Set up two-factor authentication'),
          ),
      ],
    );
  }

  Widget _backupCodes() {
    if (_codes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return _Section(
      title: 'Backup codes',
      trailing: _State(label: 'Shown once', positive: false),
      children: [
        Text(
          'Each one signs you in once if your authenticator app is gone. '
          'Save them now — this list is not shown again, and generating a new '
          'set invalidates these.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        SelectableText(
          _codes.join('\n'),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['monospace'],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => _codes = const []),
            child: const Text('I have saved them'),
          ),
        ),
      ],
    );
  }

  Widget _phoneSection(SecurityPanel panel) {
    final theme = Theme.of(context);
    final phone = panel.phone;

    return _Section(
      title: 'Mobile number',
      trailing: _State(
        label: phone.verified ? 'Verified' : 'Not verified',
        positive: phone.verified,
      ),
      children: [
        Text(
          phone.verified
              ? '${phone.number} is verified. This proves you hold the number, '
                    'which is what registration and Coffee Key purchases check. '
                    'An SMS code is never accepted at sign-in.'
              : 'We text a six-digit code to confirm you hold this number.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          enabled: !_busy,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          decoration: const InputDecoration(labelText: 'Mobile number'),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _busy ? null : _sendPhoneCode,
          child: Text(phone.verified ? 'Send a new code' : 'Send code'),
        ),
        if (panel.message != null && panel.outcome != null) ...[
          const SizedBox(height: 10),
          Text(
            panel.outcome == 'sent' && panel.retryInSeconds != null
                // The resend window the server just opened, in its own seconds.
                ? '${panel.message} You can ask for another in '
                      '${panel.retryInSeconds} seconds.'
                : panel.message!,
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (panel.developmentPhoneCode != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            'Development only — this server has no SMS gateway, so the code is '
            '${panel.developmentPhoneCode}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (_phoneCodeSent) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              labelText: 'Code from the text message',
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _verifyPhoneCode,
            child: const Text('Verify number'),
          ),
        ],
      ],
    );
  }

  Widget _devices(SecurityPanel panel) {
    final theme = Theme.of(context);

    return _Section(
      title: 'Signed-in devices',
      children: [
        if (panel.devices.isEmpty)
          Text(
            'No device records yet — sign-ins only started being listed with '
            'this screen, so this session appears after the next sign-in.',
            style: theme.textTheme.bodyMedium,
          ),
        for (final device in panel.devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              device.isCurrent ? '${device.label} · this device' : device.label,
            ),
            subtitle: Text(
              device.ip.isEmpty
                  ? 'signed in ${_when(device.signedInAt)}'
                  : '${device.ip} · signed in ${_when(device.signedInAt)}',
              style: theme.textTheme.bodySmall,
            ),
            trailing: device.isCurrent
                ? null
                : TextButton(
                    onPressed: _busy || _codes.isNotEmpty
                        ? null
                        : () => _revoke(device),
                    child: const Text('Revoke'),
                  ),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy || _codes.isNotEmpty ? null : _signOutEverywhere,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
          child: const Text('Sign out everywhere'),
        ),
        Text(
          'Revokes every device and refuses any session issued before now, '
          'including ones older than this list. You end up signed out here too.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _usage(SecurityPanel panel) {
    final theme = Theme.of(context);
    final usage = panel.usage;
    final fraction = usage.fractionUsed;

    return _Section(
      title: 'Usage & membership',
      trailing: _State(
        label: usage.metered
            ? '${usage.plan} plan'
            : '${usage.plan} · unmetered',
        positive: true,
      ),
      children: [
        if (usage.organization.isNotEmpty)
          Text(usage.organization, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        if (fraction == null)
          Text(
            'This plan has no daily token ceiling.',
            style: theme.textTheme.bodyMedium,
          )
        else ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: fraction, minHeight: 8),
          ),
          const SizedBox(height: 8),
          Text(
            '${usage.used} of ${usage.cap} tokens used today · '
            '${usage.remaining} left. The count resets at midnight.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  String _when(DateTime? moment) {
    if (moment == null) return 'recently';
    final local = moment.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} h ago';
    return '${local.year}-${_two(local.month)}-${_two(local.day)}';
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}

/// A labelled block with an optional right-aligned state chip.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

class _State extends StatelessWidget {
  const _State({required this.label, required this.positive});

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = positive
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// The step that finishes an enrollment: the key, and the code built from it.
class _Enrollment extends StatelessWidget {
  const _Enrollment({
    required this.enrollment,
    required this.busy,
    required this.controller,
    required this.onActivate,
    required this.onCancel,
  });

  final TwoFactorEnrollment enrollment;
  final bool busy;
  final TextEditingController controller;
  final Future<void> Function() onActivate;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Add this account to your authenticator app with the QR code or '
          'manual key below. Nothing changes until a code built from it is '
          'confirmed — opening this screen does not turn anything on.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        if (enrollment.qrSvg?.trim().isNotEmpty ?? false) ...[
          Center(
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SvgPicture.string(
                  enrollment.qrSvg!,
                  width: 220,
                  height: 220,
                  semanticsLabel: 'Authenticator setup QR code',
                  errorBuilder: (context, error, stackTrace) => const SizedBox(
                    width: 220,
                    child: Text(
                      'QR unavailable. Use the setup key below.',
                      style: TextStyle(color: Colors.black),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          const Text('QR unavailable. Use the setup key below.'),
          const SizedBox(height: 12),
        ],
        Text('Setup key', style: theme.textTheme.labelLarge),
        SelectableText(
          enrollment.secret,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['monospace'],
          ),
        ),
        const SizedBox(height: 8),
        Text('otpauth:// link', style: theme.textTheme.labelLarge),
        SelectableText(
          enrollment.provisioningUri,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          enabled: !busy,
          keyboardType: TextInputType.text,
          autofillHints: const [AutofillHints.oneTimeCode],
          decoration: const InputDecoration(labelText: 'Six-digit code'),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: busy ? null : onActivate,
          child: const Text('Activate two-factor'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: busy ? null : onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}
