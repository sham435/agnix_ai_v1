import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../api/models.dart';
import '../util/turn_times.dart';

/// One row the user sent.
///
/// Rendered as plain text, not Markdown: this is what the human typed, and
/// interpreting `#` or `*` in it would change the meaning of their own words.
/// Selection is handled by the [SelectionArea] that wraps the whole transcript,
/// so this bubble no longer owns a [SelectableText] of its own.
class UserTurn extends StatelessWidget {
  const UserTurn({required this.message, super.key});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    message.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              // "when I asked" - the half of the pair the request was made for.
              if (message.createdAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 2),
                  child: _TurnMeta('Asked ${clockTime(message.createdAt!)}'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row the agent produced.
///
/// Its `content` is Markdown, so it is rendered with [GptMarkdown] exactly the
/// way the request asked ("show its context formatted text to clients like
/// ChatGPT do"). Three real states share this widget, because the server writes
/// the assistant row progressively:
///
///   * placeholder, still empty - nothing to render; the screen's waiting row
///     covers it, so this returns a zero-height box;
///   * placeholder, filling in - the partial answer with a caret after it;
///   * finished - the full answer plus when it landed and what it cost.
class AssistantTurn extends StatelessWidget {
  const AssistantTurn({required this.message, super.key});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!message.hasBody) return const SizedBox.shrink();

    final streaming = message.isStreaming;
    final detail = message.errorDetail;
    final completedAt = message.completedAt;
    final elapsed = turnWait(
      askedAt: message.createdAt,
      finishedAt: completedAt,
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        // 560px keeps the prose near the 65-75 character measure the reading
        // guide asks for; the code fences inside are scrollable, not clipped.
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(6),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GptMarkdown(
                        message.content,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.6,
                        ),
                        // A reveal animation owns a ticker, and a ticker means
                        // `pumpAndSettle` never returns in a test (and burns
                        // frames for a reply that is already complete). The
                        // text still arrives token by token - it is just the
                        // fade-in of each character we opt out of.
                        animation: GptMarkdownAnimation.none,
                      ),
                      // The "still writing" caret. A static block, never a
                      // spinning indicator, so the transcript has no live
                      // ticker while the user reads a finished thread.
                      if (streaming) const _Caret(),
                    ],
                  ),
                ),
              ),
              // The cause of a failed turn travels in `metadata["error"]`; the
              // sentence in `content` is deliberately generic, so without this
              // the whole failure reads "I encountered an error". Selectable
              // through the transcript's SelectionArea, because the point is to
              // hand the exact provider message to whoever can fix it.
              if (detail != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 16,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              // The finish stamp and cost belong to a turn that actually
              // produced an answer. A failed turn "finished" too, but printing
              // "took 22s" beside "I encountered an error" reads as a success
              // metric, so the meta is dropped whenever a cause is shown.
              if (completedAt != null && detail == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _TurnMeta(_finishLine(completedAt, elapsed)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Finished 14:30:23 · took 18s · 210 tokens", dropping the parts the
  /// payload does not carry.
  String _finishLine(DateTime completedAt, Duration? elapsed) {
    final parts = <String>['Finished ${clockTime(completedAt)}'];
    if (elapsed != null) parts.add('took ${formatElapsed(elapsed)}');
    final tokens = message.tokens;
    if (tokens != null) parts.add('$tokens tokens');
    return parts.join(' · ');
  }
}

/// The "the agent is working on it" line shown while no answer text exists yet.
///
/// A label plus a static caret and an explicit elapsed counter - never a bare
/// spinning ring, which the request singled out as unhelpful ("only show Agent
/// is thinking and Loading rotation arrow in a round"). It counts seconds so a
/// long turn reads as *slow*, not as *stuck*.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({this.elapsed, super.key});

  /// The wait so far, refreshed by the screen on every poll. Null hides the
  /// counter rather than printing a fake zero.
  final Duration? elapsed;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waited = widget.elapsed;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Dots(reducedMotion: _reduceMotion(context)),
            const SizedBox(width: 10),
            Text(
              waited == null
                  ? 'Agent is working'
                  : 'Agent is working · ${formatElapsed(waited)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _reduceMotion(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}

/// Three dots that pulse in sequence, or sit still under
/// `prefers-reduced-motion`. The AnimationController is the only ticker in the
/// transcript and it only runs while a reply is genuinely outstanding.
class _Dots extends StatefulWidget {
  const _Dots({required this.reducedMotion});

  final bool reducedMotion;

  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reducedMotion) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _Dots old) {
    super.didUpdateWidget(old);
    if (widget.reducedMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 22,
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final phase = widget.reducedMotion ? 0.0 : _controller.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (i) {
              final shift = (phase + i / 3) % 1.0;
              final scale = 0.55 + 0.45 * (1 - (shift - 0.5).abs() * 2);
              return SizedBox.square(
                dimension: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.35 + 0.4 * scale),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// The block that trails a partially written answer.
class _Caret extends StatelessWidget {
  const _Caret();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        width: 8,
        height: 16,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// The quiet metadata line under a turn - "Asked …", "Finished … · took …".
class _TurnMeta extends StatelessWidget {
  const _TurnMeta(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.2,
      ),
    );
  }
}
