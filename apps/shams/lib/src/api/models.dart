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
    this.updatedAt,
    this.tokens,
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

  /// When this row was last written.
  ///
  /// For an assistant row this is the moment the answer became final, and it
  /// can be trusted as one: `AgentRunner`'s last write is the only `update!`
  /// that ever touches the row after the placeholder exists, while the partial
  /// text `AgentStreamJob` streams in goes through `update_column`, which by
  /// design does not move `updated_at`. So "asked at / finished at" comes from
  /// data the server already sends instead of a clock the client guessed.
  final DateTime? updatedAt;

  /// Tokens this turn cost, when the server recorded it.
  final int? tokens;

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
    updatedAt: _date(json['updated_at']),
    tokens: json['tokens'] is int ? json['tokens'] as int : null,
  );

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  bool get isStreaming => metadata['streaming'] == true;

  /// Whether anything has been written to this row yet.
  ///
  /// `AgentStreamJob` persists the partial answer into the placeholder as the
  /// model produces it, so an assistant row goes through three real states and
  /// the transcript has to tell two of them apart: created but empty (nothing
  /// to show but the wait), filling in (show the words, keep the indicator),
  /// and finished (show the words, show when it ended).
  bool get hasBody => content.trim().isNotEmpty;

  /// When this answer stopped being a placeholder, or null if it still is one.
  DateTime? get completedAt => isStreaming ? null : updatedAt;

  /// Why this turn failed, whenever the server recorded a cause.
  ///
  /// `AgentRunner` stores a fixed, safe sentence in `content` and keeps the
  /// real reason in `metadata["error"]`, so a thread that only prints `content`
  /// repeats a placeholder and hides the answer. Measured on a live failed
  /// turn from `GET /api/v1/conversations/:id`:
  ///
  ///     "content":  "I encountered an error while processing your request."
  ///     "metadata": {"error": "Anthropic API error: HTTP 401 - {...
  ///                  \"message\":\"x-api-key header is required\"...}",
  ///                  "stream_started_at": "2026-11-03T17:44:21Z"}
  String? get errorDetail {
    final error = metadata['error'];
    if (error is String && error.isNotEmpty) return error;
    return null;
  }
}

/// The account & security panel as `GET /api/v1/security` describes it, plus
/// whatever the action that just ran chose to add to the same object.
///
/// One class rather than five because the server answers a mutation with the
/// refreshed state and the result of the action together — a client that
/// confirmed an enrollment gets the new backup codes in the same response, and
/// those codes exist nowhere else.
class SecurityPanel {
  const SecurityPanel({
    required this.twoFactorEnabled,
    required this.recoveryCodesLeft,
    required this.lockedMinutesLeft,
    required this.phone,
    required this.devices,
    required this.usage,
    this.recoveryCodes = const [],
    this.enrollment,
    this.message,
    this.outcome,
    this.retryInSeconds,
    this.developmentPhoneCode,
    this.signedOut = false,
  });

  final bool twoFactorEnabled;

  /// Backup codes still unspent. New ones are only ever handed out by a
  /// response — [recoveryCodes] — and generating a set retires the last.
  final int recoveryCodesLeft;

  /// Minutes the account's second factor is paused after too many wrong codes.
  final int lockedMinutesLeft;

  final PhoneStatus phone;
  final List<DeviceSession> devices;
  final UsageStatus usage;

  /// Non-empty only in the response that minted them.
  final List<String> recoveryCodes;

  /// The half-finished enrollment: a key the account has not accepted yet.
  final TwoFactorEnrollment? enrollment;

  final String? message;

  /// The phone verifier's own status (`sent`, `verified`, `cooldown`, …), which
  /// the screen shows instead of inventing a state it has not seen.
  final String? outcome;
  final int? retryInSeconds;

  /// Set only by a server with no SMS gateway, for the session that asked.
  final String? developmentPhoneCode;

  /// True when the call ended this client's own session.
  final bool signedOut;

  factory SecurityPanel.fromJson(Map<String, dynamic> json) {
    final twoFactor = _section(json['two_factor']);
    final phone = _section(json['phone']);
    final usage = _section(json['usage']);
    final enrollment = _section(json['enrollment']);

    return SecurityPanel(
      twoFactorEnabled: _flag(twoFactor['enabled']),
      recoveryCodesLeft: _int(twoFactor['recovery_codes_left']) ?? 0,
      lockedMinutesLeft: _int(twoFactor['locked_minutes_left']) ?? 0,
      phone: PhoneStatus(
        number: phone['number'] is String ? phone['number'] as String : '',
        verified: _flag(phone['verified']),
        verifiedAt: _date(phone['verified_at']),
      ),
      devices: (json['devices'] is List)
          ? (json['devices'] as List)
                .whereType<Map<String, dynamic>>()
                .map(DeviceSession.fromJson)
                .toList(growable: false)
          : const [],
      usage: UsageStatus(
        organization: usage['organization'] is String
            ? usage['organization'] as String
            : '',
        plan: usage['plan'] is String ? usage['plan'] as String : 'free',
        metered: _flag(usage['metered']),
        cap: _int(usage['cap']),
        used: _int(usage['used']) ?? 0,
        remaining: _int(usage['remaining']),
      ),
      recoveryCodes: (json['recovery_codes'] is List)
          ? (json['recovery_codes'] as List).whereType<String>().toList(
              growable: false,
            )
          : const [],
      enrollment: enrollment.isEmpty
          ? null
          : TwoFactorEnrollment(
              secret: enrollment['secret'] is String
                  ? enrollment['secret'] as String
                  : '',
              provisioningUri: enrollment['provisioning_uri'] is String
                  ? enrollment['provisioning_uri'] as String
                  : '',
              expiresInSeconds: _int(enrollment['expires_in']) ?? 0,
            ),
      message: json['message'] is String ? json['message'] as String : null,
      outcome: json['status'] is String ? json['status'] as String : null,
      retryInSeconds: _int(json['retry_in']),
      developmentPhoneCode: json['code'] is String
          ? json['code'] as String
          : null,
      signedOut: json['signed_out'] == true,
    );
  }
}

class PhoneStatus {
  const PhoneStatus({
    required this.number,
    required this.verified,
    this.verifiedAt,
  });

  final String number;
  final bool verified;
  final DateTime? verifiedAt;
}

/// One signed-in device. `id` is what a revoke call addresses.
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.label,
    required this.ip,
    required this.isCurrent,
    this.signedInAt,
    this.lastSeenAt,
  });

  final String id;
  final String label;
  final String ip;

  /// The device this request came from — the one the panel gives no revoke
  /// button, because signing out here is already the sign-out control.
  final bool isCurrent;
  final DateTime? signedInAt;
  final DateTime? lastSeenAt;

  factory DeviceSession.fromJson(Map<String, dynamic> json) => DeviceSession(
    id: _id(json['id']),
    label: json['device'] is String
        ? json['device'] as String
        : 'Unknown device',
    ip: json['ip'] is String ? json['ip'] as String : '',
    isCurrent: _flag(json['current']),
    signedInAt: _date(json['signed_in_at']),
    lastSeenAt: _date(json['last_seen_at']),
  );
}

/// Today's quota for the active organization.
///
/// An unmetered plan reports `metered: false` with a null cap; that is "no
/// daily ceiling", never "nothing left".
class UsageStatus {
  const UsageStatus({
    required this.organization,
    required this.plan,
    required this.metered,
    required this.cap,
    required this.used,
    required this.remaining,
  });

  final String organization;
  final String plan;
  final bool metered;
  final int? cap;
  final int used;
  final int? remaining;

  /// 0.0–1.0 of the day's budget spent, or null when there is no budget.
  double? get fractionUsed {
    final cap = this.cap;
    if (!metered || cap == null || cap <= 0) return null;
    final value = used / cap;
    if (value < 0) return 0;
    return value > 1 ? 1 : value;
  }
}

/// A pending two-factor key: shown so an authenticator app can be told about
/// this account, and worth nothing until a code built from it is confirmed.
class TwoFactorEnrollment {
  const TwoFactorEnrollment({
    required this.secret,
    required this.provisioningUri,
    required this.expiresInSeconds,
  });

  final String secret;
  final String provisioningUri;
  final int expiresInSeconds;
}

Map<String, dynamic> _section(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

int? _int(Object? value) => value is int ? value : null;

/// A security flag, read as it is: an absent or malformed one is false. The
/// `_bool` above defaults to true because a missing `is_active` on an agent
/// means the row is live; nothing about protection may be assumed on absent
/// data.
bool _flag(Object? value) => value == true;

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
