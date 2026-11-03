/// The subset of the Rails v1 JSON payloads this app renders.
///
/// Parsing stays defensive: an unexpected or missing key degrades to a
/// fallback instead of throwing.
///
/// Ids are strings because the server's primary keys are UUIDs
/// (`create_table "conversations", id: :uuid`), which `rails runner` confirms
/// for every payload this client reads. `mobile/src/api/types.ts` declares them
/// as `number`; that is wrong against this API and is exactly the kind of
/// assumption this file is not allowed to inherit - a UUID parsed as an int
/// becomes 0, and any URL built from it points at nothing.
library;

class Agent {
  const Agent({
    required this.id,
    required this.name,
    this.slug,
    this.description,
    this.model = '',
    this.provider = '',
    this.isActive = true,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String? slug;
  final String? description;
  final String model;
  final String provider;
  final bool isActive;
  final DateTime? updatedAt;

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
    id: _id(json['id']),
    name: (json['name'] as String?) ?? 'Untitled agent',
    slug: json['slug'] as String?,
    description: json['description'] as String?,
    model: (json['model'] as String?) ?? '',
    provider: (json['provider'] as String?) ?? '',
    isActive: _bool(json['is_active']),
    updatedAt: _date(json['updated_at']),
  );

  String get subtitle {
    final parts = <String>[
      if (provider.isNotEmpty) provider,
      if (model.isNotEmpty) model,
    ];
    return parts.isEmpty ? 'no model configured' : parts.join(' · ');
  }
}

class Conversation {
  const Conversation({
    required this.id,
    required this.status,
    this.title,
    this.agentId,
    this.agent,
    this.messages = const [],
    this.updatedAt,
  });

  final String id;
  final String status;
  final String? title;
  final String? agentId;

  /// `GET /api/v1/conversations` embeds the agent (`include: :agent`).
  final Agent? agent;

  /// Only `GET /api/v1/conversations/:id` sends messages
  /// (`include: { messages: { include: :agent } }`); the list leaves this empty.
  final List<Message> messages;
  final DateTime? updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: _id(json['id']),
    status: (json['status'] as String?) ?? 'active',
    title: json['title'] as String?,
    agentId: json['agent_id'] == null ? null : _id(json['agent_id']),
    agent: json['agent'] is Map<String, dynamic>
        ? Agent.fromJson(json['agent'] as Map<String, dynamic>)
        : null,
    messages: (json['messages'] is List)
        ? (json['messages'] as List)
              .whereType<Map<String, dynamic>>()
              .map(Message.fromJson)
              .toList(growable: false)
        : const [],
    updatedAt: _date(json['updated_at']),
  );

  /// The agent behind this thread, wherever the payload chose to put it.
  ///
  /// `GET /api/v1/conversations` embeds `agent` on the conversation, while
  /// `GET /api/v1/conversations/:id` embeds it on each *message* and leaves the
  /// conversation without one - so the detail read falls back to the newest
  /// message that carries an agent.
  Agent? get effectiveAgent {
    if (agent != null) return agent;
    for (final message in messages.reversed) {
      if (message.agent != null) return message.agent;
    }
    return null;
  }

  String get displayName {
    final title = this.title;
    if (title != null && title.isNotEmpty) return title;
    final agentName = effectiveAgent?.name;
    if (agentName != null && agentName.isNotEmpty) return agentName;
    return 'Untitled conversation';
  }

  /// True while the server has an assistant row still being written.
  ///
  /// `Conversations::StartChat` and `Api::V1::MessagesController` both create
  /// the reply as a placeholder carrying `metadata["streaming"] = true`, and
  /// `AgentStreamJob` clears it when the answer lands - so this is the signal
  /// the chat screen polls on instead of a guessed delay.
  bool get awaitingReply => messages.any((message) => message.isStreaming);
}

/// One turn in a conversation.
class Message {
  const Message({
    required this.id,
    required this.role,
    required this.content,
    this.conversationId,
    this.agentId,
    this.agent,
    this.metadata = const {},
    this.createdAt,
  });

  final String id;
  final String role;
  final String content;
  final String? conversationId;
  final String? agentId;

  /// `GET /api/v1/conversations/:id` embeds the agent on every message, which
  /// is how a thread opened straight from that endpoint learns its model.
  final Agent? agent;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    id: _id(json['id']),
    role: (json['role'] as String?) ?? '',
    content: (json['content'] as String?) ?? '',
    conversationId: json['conversation_id'] == null
        ? null
        : _id(json['conversation_id']),
    agentId: json['agent_id'] == null ? null : _id(json['agent_id']),
    agent: json['agent'] is Map<String, dynamic>
        ? Agent.fromJson(json['agent'] as Map<String, dynamic>)
        : null,
    metadata: json['metadata'] is Map<String, dynamic>
        ? json['metadata'] as Map<String, dynamic>
        : const {},
    createdAt: _date(json['created_at']),
  );

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  bool get isStreaming => metadata['streaming'] == true;
}

/// A UUID (or, defensively, any scalar) rendered as the string the API uses.
String _id(Object? value) {
  if (value is String) return value;
  if (value == null) return '';
  return value.toString();
}

bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString();
  if (text == null) return true;
  return text == 'true' || text == 't' || text == '1';
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
