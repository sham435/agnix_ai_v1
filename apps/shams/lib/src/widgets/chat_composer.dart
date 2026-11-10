import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// The message field and its send button.
///
/// `busy` means "no new turn may be posted" - either this client's own POST is
/// in flight, or the agent is still writing the reply to the turn before. Both
/// the field and the button are disabled then, so the lock the user sees is the
/// same lock [ChatScreen] (see chat_screen.dart) uses to decide whether to
/// start a second `AgentStreamJob`; the two can never disagree.
///
/// Enter-to-send on desktop: this build's `TextField` is multiline, so inside
/// it Enter inserts a newline. A parent [Focus.onKeyEvent] intercepts Enter
/// (without Shift, and not during IME composition) and hands the turn to
/// [onSubmit] exactly as if the send button had been tapped - while mobile
/// keeps its `TextInputAction.send` behaviour untouched.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    required this.controller,
    required this.busy,
    required this.onSubmit,
    super.key,
  });

  final TextEditingController controller;
  final bool busy;
  final Future<void> Function() onSubmit;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  /// The field's own focus node, carrying the Enter interception directly:
  /// key events reach this handler *before* any default newline handling,
  /// which is the only deterministic way to convert desktop Enter to submit.
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKeyEvent);

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.busy) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (event is! KeyDownEvent || !isEnter) return KeyEventResult.ignored;
    // Shift+Enter stays a newline, as the desktop conventions expect.
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    // A live IME composition (e.g. CJK candidate text) is not confirmable text
    // yet, so Enter there belongs to the IME, not to us.
    final composing = widget.controller.value.composing != TextRange.empty;
    if (composing) return KeyEventResult.ignored;
    widget.onSubmit();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                enabled: !widget.busy,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.send,
                  style: theme.textTheme.bodyLarge,
                  onSubmitted: (_) => widget.onSubmit(),
                  decoration: InputDecoration(
                    hintText: 'Message shams ai…',
                    filled: true,
                    fillColor: scheme.surfaceContainer,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                    // The pill. A 24px radius over a ~48px field is the capsule
                    // of the reference client; the focus ring is the violet
                    // primary.
                    enabledBorder: _pillBorder(scheme.outline),
                    focusedBorder: _pillBorder(scheme.primary, width: 1.5),
                    disabledBorder: _pillBorder(scheme.outline),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            // A 44x44 target - the smallest tap the accessibility guide allows -
            // filled so the disabled state is legible without colour alone: the
            // icon swaps to a static hourglass and the tooltip names the wait.
            // When live it carries the brand gradient (one of the surfaces the
            // brief reserves it for); when locked it greys out with the theme's
            // disabled fill.
            SizedBox.square(
              dimension: 44,
              child: FilledButton(
                onPressed: widget.busy ? null : widget.onSubmit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.square(44),
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  shape: const CircleBorder(),
                ),
                child: Ink(
                  decoration: BoxDecoration(
                    gradient: widget.busy ? null : brandLinearGradient(),
                    color: widget.busy ? scheme.surfaceContainerHigh : null,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.busy ? Icons.hourglass_empty : Icons.send,
                    size: 20,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  OutlineInputBorder _pillBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(color: color, width: width),
      );
}
