import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/shams_api.dart';

/// How often the chat screen re-reads the conversation while a reply is being
/// generated, and the hard stop for that polling.
///
/// The server answers `messages#create` as soon as the user row is saved and
/// writes the assistant reply from `AgentStreamJob`, so a client that wants the
/// answer has to keep looking. Polling stops when no message is still flagged
/// `metadata["streaming"]`, when the screen goes away, or after
/// [_maxWait] - the last one because a job that died mid-run would otherwise
/// leave the screen spinning forever.
const Duration _pollInterval = Duration(milliseconds: 1200);
const Duration _maxWait = Duration(minutes: 10);

/// A conversation: the transcript, a thinking indicator while the agent works,
/// and a composer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.api,
    required this.conversationId,
    super.key,
    this.title,
    this.agent,
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
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
      _stickToBottom();
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

  /// Starts or stops the poll depending on whether a placeholder is still open.
  void _trackWait(Conversation conversation) {
    if (!conversation.awaitingReply) {
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
      _load(keepError: true);
    });
  }

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await widget.api.sendMessage(widget.conversationId, content);
      _controller.clear();
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _stickToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
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
    final awaiting = conversation?.awaitingReply ?? false;
    final agent = conversation?.effectiveAgent ?? widget.agent;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _heading(conversation, agent),
              overflow: TextOverflow.ellipsis,
            ),
            if (agent != null)
              Text(
                '${agent.name} · ${agent.subtitle}',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : messages.isEmpty && !awaiting
                  ? _EmptyThread(origin: widget.api.origin)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      itemCount: messages.length + (awaiting ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= messages.length) {
                          return const _ThinkingRow();
                        }
                        return _Bubble(message: messages[index]);
                      },
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
          _Composer(controller: _controller, busy: _sending, onSubmit: _send),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = message.isUser;
    final detail = message.errorDetail;

    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 640),
        decoration: BoxDecoration(
          color: user
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: user
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              message.content.isEmpty ? '…' : message.content,
              style: theme.textTheme.bodyMedium,
            ),
            // The stored sentence is deliberately generic, so a failed turn is
            // otherwise unreadable: "I encountered an error" tells you nothing
            // while `metadata["error"]` already says `x-api-key header is
            // required`. Selectable, because the whole point is being able to
            // hand the exact provider message to someone who can fix it.
            if (detail != null) ...[
              const SizedBox(height: 6),
              SelectableText(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Agent is thinking',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread({required this.origin});

  final String origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No messages yet. Say something.\n\nConnected to $origin',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool busy;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
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
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
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
