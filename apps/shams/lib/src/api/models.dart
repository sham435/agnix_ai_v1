/// The subset of the Rails v1 JSON payloads this app renders.
///
/// Field names mirror `mobile/src/api/types.ts` so both clients describe the
/// same API contract, and parsing stays defensive: an unexpected or missing key
/// degrades to a fallback instead of throwing.
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

  final int id;
  final String name;
  final String? slug;
  final String? description;
  final String model;
  final String provider;
  final bool isActive;
  final DateTime? updatedAt;

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
    id: _int(json['id']),
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
    this.updatedAt,
  });

  final int id;
  final String status;
  final String? title;
  final int? agentId;

  /// `GET /api/v1/conversations` embeds the agent (`include: :agent`).
  final Agent? agent;
  final DateTime? updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: _int(json['id']),
    status: (json['status'] as String?) ?? 'active',
    title: json['title'] as String?,
    agentId: json['agent_id'] == null ? null : _int(json['agent_id']),
    agent: json['agent'] is Map<String, dynamic>
        ? Agent.fromJson(json['agent'] as Map<String, dynamic>)
        : null,
    updatedAt: _date(json['updated_at']),
  );

  String get displayName {
    final title = this.title;
    if (title != null && title.isNotEmpty) return title;
    final agentName = agent?.name;
    if (agentName != null && agentName.isNotEmpty) return agentName;
    return 'Conversation #$id';
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
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
