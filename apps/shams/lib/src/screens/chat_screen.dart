import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/shams_api.dart';
import '../widgets/brand_mark.dart';
import '../widgets/chat_composer.dart';
import '../widgets/prompt_card.dart';
import '../widgets/theme_button.dart';
import '../widgets/placeholder_shimmer.dart';
import '../widgets/transcript.dart';

/// How often the chat screen re-reads the conversation while a reply is being
/// generated, and the hard stop for that polling.
///
/// The server answers `messages#create` as soon as the user row is saved and
/// writes the assistant reply from `AgentStreamJob`, so a client that wants the
/// answer has to keep looking. Polling stops when the reply has arrived and is
/// no longer flagged `metadata["streaming"]`, when the screen goes away, or
/// after [_maxWait] - the last one because a job that died mid-run would
/// otherwise leave the screen spinning forever.
///
/// Note the second half of that first condition. `AgentStreamJob` creates the
/// streaming placeholder *after* the POST has already returned, so "no
/// placeholder in this read" is not the same as "no reply is coming".
const Duration _pollInterval = Duration(milliseconds: 1200);
const Duration _maxWait = Duration(minutes: 10);

/// How close to the bottom counts as "still following the conversation".
///
/// The transcript only auto-scrolls while the reader is inside this margin, so
/// scrolling up to re-read an earlier turn is never fought by a new poll.
const double _bottomTolerance = 120;

/// A conversation: the transcript, a thinking indicator while the agent works,
/// and a composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.api,
    required this.conversationId,
    super.key,
    this.title,
    this.agent,
    this.onNewChat,
  });

  final ShamsApi api;
  final String conversationId;
  final String? title;

  /// The agent this thread runs on, used until the read answers with one.
  ///
  /// `GET /api/v1/conversations/:id` embeds the agent on the *messages*
  /// (`include: { messages: { include: :agent } }`) and never on the
  /// conversation, and a conversation started without a first turn has no
  /// messages at all - so the picker hands over the agent it just chose rather
  /// than leave the header without a model.
  final Agent? agent;

  /// The home screen's new-chat flow, from the header action. Optional: only
  /// wired where a "start a different thread" affordance makes sense.
  final VoidCallback? onNewChat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  Conversation? _conversation;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  Timer? _poll;
  Stopwatch? _waiting;

  /// Whether the reader is parked at the bottom of the transcript.
  ///
  /// Starts true so the first load lands on the newest turn; a poll that adds
  /// text then keeps the view pinned there, while a reader who has scrolled up
  /// is left where they are and offered a jump-back pill instead.
  bool _atBottom = true;

  /// True between "this client posted a turn" and "the answer to that turn is
  /// on screen".
  ///
  /// `_conversation.awaitingReply` cannot cover this window on its own: the
  /// placeholder it looks for is created by `AgentStreamJob`, which starts
  /// after the POST has already returned. Measured live on 2026-11-04 - a "hi"
  /// sent at 23:17:19 produced exactly one `GET /api/v1/conversations/:id`,
  /// which read the conversation before the job had written anything, so
  /// `awaitingReply` was false, no poll was armed, and the 171-character reply
  /// the agent stored at 23:17:4x was never shown.
  bool _expectReply = false;

  /// The newest assistant message this screen had seen when the turn was
  /// posted, so a later read can tell "the reply to my turn" apart from "the
  /// reply to the turn before it".
  String? _baselineAssistantId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final distance = position.maxScrollExtent - position.pixels;
    final near = distance <= _bottomTolerance;
    if (near != _atBottom) setState(() => _atBottom = near);
  }

  Future<void> _load({bool keepError = false}) async {
    try {
      final conversation = await widget.api.conversation(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _conversation = conversation;
        _loading = false;
        if (!keepError) _error = null;
      });
      _followBottom();
      _trackWait(conversation);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.unauthorized
            ? 'Your session has ended. Sign in again.'
            : error.message;
      });
    }
  }

  /// The newest assistant row in the thread, or null if there is none.
  ///
  /// `AgentStreamJob` writes the placeholder and the finished answer to the
  /// *same* row, so this id is stable across the streaming transition and is
  /// safe to use as "have I moved past what I already knew?".
  String? _newestAssistantId(Conversation conversation) {
    for (final message in conversation.messages.reversed) {
      if (message.isAssistant) return message.id;
    }
    return null;
  }

  /// Starts or stops the poll depending on whether a reply is still outstanding.
  ///
  /// Two things can mean "still outstanding": the server's own placeholder
  /// (`awaitingReply`) and this client's expectation ([_expectReply]). The
  /// second one exists because the first can be late - see [_expectReply].
  void _trackWait(Conversation conversation) {
    if (conversation.awaitingReply) {
      // The placeholder is visible, so the server is now the authority on when
      // the turn is over; the optimistic flag has done its job.
      _expectReply = false;
    } else if (_expectReply) {
      final newest = _newestAssistantId(conversation);
      if (newest != null && newest != _baselineAssistantId) {
        // An assistant row this screen has not seen before, with no streaming
        // flag: the job ran between two reads and the answer is already final.
        _expectReply = false;
      }
    }

    if (!conversation.awaitingReply && !_expectReply) {
      _poll?.cancel();
      _poll = null;
      _waiting = null;
      if (mounted) setState(() {});
      return;
    }

    _waiting ??= Stopwatch()..start();
    if (_poll != null) return;

    _poll = Timer.periodic(_pollInterval, (_) {
      final waited = _waiting?.elapsed ?? Duration.zero;
      if (waited > _maxWait) {
        _poll?.cancel();
        _poll = null;
        if (mounted) {
          setState(
            () => _error =
                'The agent is still working. This conversation has been open '
                'longer than ${_maxWait.inMinutes} minutes, so the app stopped '
                'checking - pull to refresh to look again.',
          );
        }
        return;
      }
      // Repaint the elapsed counter even before the fetch resolves, so a slow
      // turn visibly ticks instead of looking frozen.
      _load(keepError: true);
    });
  }

  /// Whether an answer to a turn in this thread is still outstanding.
  ///
  /// Unions the server's own signal (a message flagged `metadata["streaming"]`)
  /// with this client's expectation, and is what the composer lock, the
  /// "Agent is working" row and the poll all key off - so they cannot disagree
  /// about whether a second turn may be posted.
  bool get _replyOutstanding =>
      (_conversation?.awaitingReply ?? false) || _expectReply;

  Future<void> _send() async {
    final content = _controller.text.trim();
    // `awaitingReply` is the important half of this guard. The composer used to
    // re-enable as soon as the POST returned, which is seconds before the
    // agent's answer exists, so a second tap started a second `AgentStreamJob`
    // on the same conversation: measured live, one message sent twice 64 s
    // apart produced two runs, and the first stored an empty reply.
    if (content.isEmpty || _sending || _replyOutstanding) {
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
      // A turn this client is posting is worth following to the bottom, even
      // if the reader had scrolled up to look at something else.
      _atBottom = true;
      // Take the baseline from what this screen currently knows, then hand the
      // turn over to the poll: the placeholder may not exist by the time the
      // read after this POST lands.
      _baselineAssistantId = _conversation == null
          ? null
          : _newestAssistantId(_conversation!);
      _expectReply = true;
    });

    try {
      await widget.api.sendMessage(widget.conversationId, content);
      _controller.clear();
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      // The user row was not saved, so there is genuinely no answer to wait for.
      setState(() {
        _error = error.message;
        _expectReply = false;
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Keeps the view on the newest turn - but only if the reader was already
  /// there. Jumping the scroll for someone who scrolled up is the exact thing
  /// a live-updating transcript must not do.
  void _followBottom() {
    if (!_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _jumpToLatest() {
    setState(() => _atBottom = true);
    _scrollToEnd();
  }

  /// Puts the text of an example prompt into the composer.
  ///
  /// Purely client-side: it fills the very `TextEditingController` the user
  /// types into and posts nothing anywhere. The send action stays the user's.
  void _applyPrompt(String text) {
    _controller.text = text;
  }

  /// The thread's own title, else the agent it runs on, else what the caller
  /// had to go on. `Conversations::StartChat` names a thread after its first
  /// turn, so a conversation started empty genuinely has no title yet.
  String _heading(Conversation? conversation, Agent? agent) {
    final title = conversation?.title;
    if (title != null && title.isNotEmpty) return title;
    if (agent != null) return agent.name;
    return conversation?.displayName ?? widget.title ?? 'Conversation';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conversation = _conversation;
    final messages = conversation?.messages ?? const <Message>[];
    final awaiting = _replyOutstanding;
    final agent = conversation?.effectiveAgent ?? widget.agent;

    // Once a streaming row is filling in, the answer itself is the progress
    // indicator - the separate "working" line would only duplicate it.
    final last = messages.isEmpty ? null : messages.last;
    final streamingWithBody =
        last != null && last.isAssistant && last.isStreaming && last.hasBody;
    final showWaitingRow = awaiting && !streamingWithBody;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: Row(
          children: [
            const BrandMark(size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _heading(conversation, agent),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: theme.textTheme.titleLarge,
                  ),
                  if (agent != null)
                    Text(
                      '${agent.name} · ${agent.subtitle}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.labelSmall,
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          const ThemeButton(),
          if (widget.onNewChat != null)
            IconButton(
              tooltip: 'New chat',
              onPressed: () async {
                // Same-navigation choice: leave this thread first, so the
                // "pick an agent and start fresh" flow lands in a clean back
                // stack position rather than deepening this one.
                Navigator.of(context).maybePop();
                widget.onNewChat!();
              },
              icon: const Icon(Icons.add_comment_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading
                  ? const ConversationSkeleton()
                  : messages.isEmpty && !awaiting
                  ? _EmptyThread(
                      origin: widget.api.origin,
                      onPrompt: _applyPrompt,
                    )
                  : SelectionArea(
                      // One SelectionArea over the whole thread: text inside a
                      // code fence, a heading or a list stays selectable, and
                      // the copy affordance is shared rather than per-bubble.
                      child: ListView.builder(
                        controller: _scroll,
                        // Extra bottom padding keeps the last turn clear of
                        // the composer and the jump pill.
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        itemCount: messages.length + (showWaitingRow ? 1 : 0),
                        itemBuilder: (context, index) => _centered(
                          index >= messages.length
                              ? TypingIndicator(elapsed: _waiting?.elapsed)
                              : _turnFor(messages[index]),
                        ),
                      ),
                    ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: ChatComposer(
                controller: _controller,
                busy: _sending || awaiting,
                onSubmit: _send,
              ),
            ),
          ),
        ],
      ),
      // The jump-back affordance only when a reply is arriving and the reader
      // is not looking at it.
      floatingActionButton: awaiting && !_atBottom
          ? FloatingActionButton.extended(
              onPressed: _jumpToLatest,
              icon: const Icon(Icons.keyboard_arrow_down),
              label: const Text('New turn - jump to latest'),
            )
          : null,
    );
  }

  Widget _turnFor(Message message) => message.isUser
      ? UserTurn(message: message)
      : AssistantTurn(message: message);

  /// Caps the reading measure on wide windows (desktop) without touching a
  /// phone's full width, and keeps the bubbles centred rather than flush-left
  /// in a sea of whitespace.
  Widget _centered(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: child,
    ),
  );
}

/// The placeholder shown for a conversation that has no turns yet.
///
/// Centred brand emblem, the exact headline and supporting line the spec
/// gives the welcome experience, and the example prompt cards shared with the
/// home screen's hero. The prompts only put their text into the composer the
/// way a paste would; nothing is posted anywhere.
class _EmptyThread extends StatelessWidget {
  const _EmptyThread({required this.origin, this.onPrompt});

  final String origin;

  /// Fills the composer with a tapped example prompt; user posts it.
  final ValueChanged<String>? onPrompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: _centered(
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const BrandMark(size: 40),
                  const SizedBox(height: 14),
                  Text(
                    'How can I help you today?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(fontSize: 20),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your intelligent workspace for thinking, creating and '
                    'building.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final prompt in promptSuggestions)
                        PromptCard(label: prompt, onSelected: onPrompt),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'No messages yet. Say something.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Connected to $origin',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Caps the reading measure on wide windows (desktop) without touching a
  /// phone's full width.
  Widget _centered(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 480),
    child: child,
  );
}

/// Picks an agent, which is also the model choice: `agents.model` and
/// `agents.provider` are where the model lives, and a conversation's agent
/// cannot be changed afterwards (`conversation_params` permits only title,
/// status and mode).
///
/// Returns the chosen [Agent], or null if the user backed out.
Future<Agent?> pickAgent(BuildContext context, List<Agent> agents) {
  return showModalBottomSheet<Agent?>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Start a conversation',
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          if (agents.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No agents in this space.'),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final agent in agents)
                    ListTile(
                      leading: Icon(
                        agent.isActive
                            ? Icons.smart_toy_outlined
                            : Icons.smart_toy,
                      ),
                      title: Text(agent.name),
                      subtitle: Text(agent.subtitle),
                      onTap: () => Navigator.of(sheetContext).pop(agent),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
