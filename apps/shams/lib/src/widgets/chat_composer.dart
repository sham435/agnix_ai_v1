import 'package:flutter/material.dart';

/// The message field and its send button.
///
/// `busy` means "no new turn may be posted" - either this client's own POST is
/// in flight, or the agent is still writing the reply to the turn before. Both
/// the field and the button are disabled then, so the lock the user sees is the
/// same lock [ChatScreen] uses to decide whether to start a second
/// `AgentStreamJob`; the two can never disagree.
class ChatComposer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !busy,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSubmit(),
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: theme.colorScheme.outline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // A 44x44 target - the smallest tap the accessibility guide allows -
            // filled so the disabled state is legible without colour alone: the
            // icon swaps to a static hourglass and the tooltip names the wait.
            SizedBox.square(
              dimension: 44,
              child: FilledButton(
                onPressed: busy ? null : onSubmit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.square(44),
                  padding: EdgeInsets.zero,
                ),
                child: busy
                    ? const Icon(Icons.hourglass_empty, size: 20)
                    : const Icon(Icons.send),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
