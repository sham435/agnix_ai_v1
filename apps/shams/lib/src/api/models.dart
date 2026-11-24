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

/// Server-discovered catalogue; availability never verifies inference.
class ModelReference {
  const ModelReference(this.providerId, this.modelId);
  final String providerId;
  final String modelId;
  factory ModelReference.fromJson(Map<String, dynamic> json) =>
      ModelReference(_id(json['provider_id']), _id(json['model_id']));
  bool matches(ModelReference? other) =>
      other != null &&
      providerId == other.providerId &&
      modelId == other.modelId;
}

class CatalogueProvider {
  CatalogueProvider.fromJson(Map<String, dynamic> json)
    : providerId = _id(json['provider_id']),
      providerName = _id(json['provider_name']),
      connectionStatus = _id(json['connection_status']),
      readiness = _id(json['readiness']),
      errorCode = json['error_code'] is String
          ? json['error_code'] as String
          : null;
  final String providerId, providerName, connectionStatus, readiness;
  final String? errorCode;
}

class CatalogueModel extends ModelReference {
  CatalogueModel.fromJson(Map<String, dynamic> json)
    : providerName = _id(json['provider_name']),
      displayName = _id(json['display_name']),
      modelDescription = _optionalString(json['model_description']),
      apiFamily = _optionalString(json['api_family']),
      availabilityStatus = _id(json['availability_status']),
      connectionStatus = _id(json['connection_status']),
      disabled = _optionalBool(json['disabled']),
      freeTier = _optionalBool(json['free_tier']),
      rateLimits = _section(json['rate_limits']),
      optionNames = _optionalStringList(json['option_names']) ?? const [],
      supportedParameters = _optionalStringList(json['supported_parameters']),
      contextWindow = _int(json['context_window']),
      maxOutputTokens = _int(json['max_output_tokens']),
      supportsTools = _optionalBool(json['supports_tools']),
      supportsStreaming = _optionalBool(json['supports_streaming']),
      supportsVision = _optionalBool(json['supports_vision']),
      supportsImages = _optionalBool(json['supports_images']),
      supportsJsonMode = _optionalBool(json['supports_json_mode']),
      supportsReasoning = _optionalBool(json['supports_reasoning']),
      reasoningParameters = _optionalStringList(json['reasoning_parameters']),
      supportsParallelToolCalls = _optionalBool(
        json['supports_parallel_tool_calls'],
      ),
      inferenceStatus = _optionalString(json['inference_status']),
      inferenceVerifiedAt = _date(json['inference_verified_at']),
      lastInferenceAttemptAt = _date(json['last_inference_attempt_at']),
      lastInferenceErrorCode = _optionalString(
        json['last_inference_error_code'],
      ),
      lastDiscoveredAt = _date(json['last_discovered_at']),
      isDefault = _optionalBool(json['is_default']),
      local = _optionalBool(json['local']),
      manageable = _optionalBool(json['manageable']),
      super(_id(json['provider_id']), _id(json['model_id']));
  final String providerName, displayName, availabilityStatus, connectionStatus;
  final String? modelDescription, apiFamily;
  final bool? disabled, freeTier;
  final Map<String, dynamic> rateLimits;
  final List<String> optionNames;
  final List<String>? supportedParameters;
  final int? contextWindow, maxOutputTokens;
  final bool? supportsTools, supportsStreaming, supportsVision;
  final bool? supportsImages, supportsJsonMode, supportsReasoning;
  final List<String>? reasoningParameters;
  final bool? supportsParallelToolCalls;
  final String? inferenceStatus;
  final DateTime? inferenceVerifiedAt, lastInferenceAttemptAt;
  final String? lastInferenceErrorCode;
  final DateTime? lastDiscoveredAt;
  final bool? isDefault, local, manageable;
  bool get selectable =>
      availabilityStatus == 'available' &&
      providerId.isNotEmpty &&
      modelId.isNotEmpty;
  String get label => displayName.isEmpty ? modelId : displayName;
}

class ModelCatalogue {
  ModelCatalogue.fromJson(Map<String, dynamic> json)
    : providers =
          (json['providers'] is List ? json['providers'] as List : const [])
              .whereType<Map<String, dynamic>>()
              .map(CatalogueProvider.fromJson)
              .toList(),
      models = (json['models'] is List ? json['models'] as List : const [])
          .whereType<Map<String, dynamic>>()
          .map(CatalogueModel.fromJson)
          .toList(),
      selectedModel = json['selected_model'] is Map<String, dynamic>
          ? ModelReference.fromJson(
              json['selected_model'] as Map<String, dynamic>,
            )
          : null,
      defaultModel = json['default_model'] is Map<String, dynamic>
          ? ModelReference.fromJson(
              json['default_model'] as Map<String, dynamic>,
            )
          : null,
      updatedAt = _date(json['catalogue_updated_at']);
  final List<CatalogueProvider> providers;
  final List<CatalogueModel> models;
  final ModelReference? selectedModel, defaultModel;
  final DateTime? updatedAt;
  ModelReference? get effectiveModel => selectedModel ?? defaultModel;
  String get selectionLabel {
    final selected = effectiveModel;
    for (final model in models) {
      if (model.matches(selected)) return model.label;
    }
    return selected?.modelId ?? 'Organization default';
  }
}

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
              qrSvg: enrollment['qr_svg'] is String
                  ? enrollment['qr_svg'] as String
                  : null,
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
    this.qrSvg,
  });

  final String secret;
  final String provisioningUri;
  final int expiresInSeconds;

  /// Optional server-rendered QR. Older servers provide only the manual key.
  final String? qrSvg;
}

/// One sandboxed Docker workspace: the project a conversation's coding turns
/// actually run in.
///
/// Two states travel together and mean different things. [state] is this
/// account's row, kept in step with what the manager confirmed; [runtimeStatus]
/// is the manager's own answer for the container right now, which is what the
/// screen shows as live. A stopped workspace has a row and no container, and
/// the difference is the whole point of showing both.
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.state,
    this.runtime = 'python3',
    this.conversationId,
    this.preview,
    this.lastError,
    this.runtimeStatus,
    this.container,
    this.files = const [],
    this.filesTruncated = false,
    this.filesError,
    this.runs = const [],
  });

  final String id;
  final String name;
  final String state;
  final String runtime;
  final String? conversationId;
  final PreviewLink? preview;
  final String? lastError;

  /// The manager's word for the container: `running`, `exited`, `absent`,
  /// `unavailable`, `restarting`, or null when this read carried no status.
  final String? runtimeStatus;
  final String? container;

  /// Project files, as the manager listed them - relative paths only.
  final List<WorkspaceFile> files;
  final bool filesTruncated;

  /// Why the listing is empty, whenever it is: an unreachable manager is a
  /// fact to report, never an empty project.
  final String? filesError;

  final List<WorkspaceRun> runs;

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final status = _section(json['status']);
    return Workspace(
      id: _id(json['id']),
      name: (json['name'] as String?) ?? 'Workspace',
      state: (json['state'] as String?) ?? 'pending',
      runtime: (json['runtime'] as String?) ?? 'python3',
      conversationId: json['conversation_id'] == null
          ? null
          : _id(json['conversation_id']),
      preview: json['preview'] is Map<String, dynamic>
          ? PreviewLink.fromJson(json['preview'] as Map<String, dynamic>)
          : null,
      lastError: json['last_error'] as String?,
      runtimeStatus: status['state'] as String?,
      container: status['container'] as String?,
      files: (json['files'] is List)
          ? (json['files'] as List)
                .whereType<Map<String, dynamic>>()
                .map(WorkspaceFile.fromJson)
                .toList(growable: false)
          : const [],
      filesTruncated: _flag(json['files_truncated']),
      filesError: json['files_error'] as String?,
      runs: (json['runs'] is List)
          ? (json['runs'] as List)
                .whereType<Map<String, dynamic>>()
                .map(WorkspaceRun.fromJson)
                .toList(growable: false)
          : const [],
    );
  }

  bool get isStopped => state == 'destroyed';

  /// True while the manager itself confirms a container is up. Only ever used
  /// to describe the sandbox, never to claim a step succeeded.
  bool get isRunning => runtimeStatus == 'running';

  /// What to print where the state lives, in the server's own words.
  String get statusLabel {
    if (isStopped) return 'Stopped';
    final live = runtimeStatus;
    if (live == null) {
      return switch (state) {
        'ready' => 'Ready',
        'pending' => 'Starting',
        'failed' => 'Failed',
        'stopped' => 'Stopped',
        _ => state,
      };
    }
    return switch (live) {
      'running' => 'Running',
      'restarting' => 'Restarting',
      'exited' => 'Exited',
      'absent' => 'Not running',
      'unavailable' => 'Manager unavailable',
      _ => live,
    };
  }
}

/// One file inside /workspace, as the manager's tree walk reported it.
class WorkspaceFile {
  const WorkspaceFile({required this.path, required this.bytes});

  final String path;
  final int bytes;

  factory WorkspaceFile.fromJson(Map<String, dynamic> json) => WorkspaceFile(
    path: (json['path'] as String?) ?? '',
    bytes: _int(json['bytes']) ?? 0,
  );

  bool get isText =>
      path.endsWith('.py') ||
      path.endsWith('.html') ||
      path.endsWith('.css') ||
      path.endsWith('.js') ||
      path.endsWith('.md') ||
      path.endsWith('.txt') ||
      path.endsWith('.ini') ||
      path.endsWith('.toml') ||
      path.endsWith('.json') ||
      path.endsWith('.yml') ||
      path.endsWith('.yaml');

  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// One recorded step in the sandbox: a command, a test run, an install, an
/// export. The server keeps the transcript, so the screen never has to.
class WorkspaceRun {
  const WorkspaceRun({
    required this.id,
    required this.kind,
    required this.ok,
    this.argv = const [],
    this.exitCode,
    this.timedOut = false,
    this.durationMs,
    this.stdout = '',
    this.stderr = '',
    this.createdAt,
  });

  final String id;

  /// `exec | test | install | export | preview` - the server's own kinds.
  final String kind;
  final bool ok;
  final List<String> argv;
  final int? exitCode;
  final bool timedOut;
  final int? durationMs;
  final String stdout;
  final String stderr;
  final DateTime? createdAt;

  factory WorkspaceRun.fromJson(Map<String, dynamic> json) => WorkspaceRun(
    id: _id(json['id']),
    kind: (json['kind'] as String?) ?? 'exec',
    ok: _flag(json['ok']),
    argv: (json['argv'] is List)
        ? (json['argv'] as List)
              .map((token) => '$token')
              .toList(growable: false)
        : const [],
    exitCode: _int(json['exit_code']),
    timedOut: _flag(json['timed_out']),
    durationMs: _int(json['duration_ms']),
    stdout: (json['stdout'] as String?) ?? '',
    stderr: (json['stderr'] as String?) ?? '',
    createdAt: _date(json['created_at']),
  );

  /// Everything the step printed, in the order the server stored it.
  String get output {
    final parts = <String>[
      if (stdout.trim().isNotEmpty) stdout.trimRight(),
      if (stderr.trim().isNotEmpty) stderr.trimRight(),
    ];
    return parts.join('\n');
  }

  String get title {
    if (argv.isNotEmpty) return argv.join(' ');
    return switch (kind) {
      'test' => 'Test run',
      'install' => 'Dependency install',
      'export' => 'Project export',
      'preview' => 'Preview server',
      _ => kind,
    };
  }
}

/// The preview link the server issued for a running preview.
///
/// [url] is the gateway path with this session's token on it: same-origin,
/// expiring, and good for this workspace only.
class PreviewLink {
  const PreviewLink({
    required this.url,
    required this.port,
    this.expiresAt,
    this.secondsLeft,
  });

  final String url;
  final int port;
  final DateTime? expiresAt;
  final int? secondsLeft;

  factory PreviewLink.fromJson(Map<String, dynamic> json) => PreviewLink(
    url: (json['url'] as String?) ?? '',
    port: _int(json['port']) ?? 0,
    expiresAt: _date(json['expires_at']),
    secondsLeft: _int(json['seconds_left']),
  );

  bool get isLive => (secondsLeft ?? 0) > 0 && url.isNotEmpty;

  /// How much life the server said the link still has, in its own words.
  String get lifetimeLabel {
    final left = secondsLeft;
    if (left == null || left <= 0) return 'expired';
    if (left < 60) return '$left s left';
    return '${(left / 60).floor()} min left';
  }
}

/// The answer to a command, a test run or a preview step.
///
/// [ok] is the server's verdict and nothing else: a refused call carries its
/// `error_code` and the manager's own reason, and the screen repeats both
/// instead of inventing a message.
class WorkspaceActionResult {
  const WorkspaceActionResult({
    required this.ok,
    this.exitCode,
    this.timedOut = false,
    this.durationSeconds,
    this.stdout = '',
    this.stderr = '',
    this.command,
    this.output,
    this.port,
    this.previewUrl,
    this.expiresIn,
    this.previewSessionToken,
    this.errorCode,
    this.error,
    this.raw = const {},
  });

  final bool ok;
  final int? exitCode;
  final bool timedOut;
  final double? durationSeconds;
  final String stdout;
  final String stderr;

  /// The test step's own fields.
  final String? command;
  final String? output;

  /// The preview step's own fields: the gateway link and its lifetime.
  final int? port;
  final String? previewUrl;
  final int? expiresIn;
  final String? previewSessionToken;

  final String? errorCode;
  final String? error;
  final Map<String, dynamic> raw;

  factory WorkspaceActionResult.fromJson(Map<String, dynamic> json) =>
      WorkspaceActionResult(
        ok: _flag(json['ok']),
        exitCode: _int(json['exit_code']),
        timedOut: _flag(json['timed_out']),
        durationSeconds: json['duration_seconds'] is num
            ? (json['duration_seconds'] as num).toDouble()
            : null,
        stdout: (json['stdout'] as String?) ?? '',
        stderr: (json['stderr'] as String?) ?? '',
        command: json['command'] as String?,
        output: json['output'] as String?,
        port: _int(json['port']),
        previewUrl: json['preview_url'] as String?,
        expiresIn: _int(json['expires_in']),
        previewSessionToken: json['preview_session_token'] as String?,
        errorCode: json['error_code'] as String?,
        error: json['error'] as String?,
        raw: json,
      );

  /// Everything this step produced, whichever shape the answer came in.
  String get transcript {
    final parts = <String>[
      if (stdout.trim().isNotEmpty) stdout.trimRight(),
      if (stderr.trim().isNotEmpty) stderr.trimRight(),
      if ((output ?? '').trim().isNotEmpty) output!.trimRight(),
      if (!ok && (errorCode != null || error != null))
        <String>[
          if (errorCode != null) errorCode!,
          if (error != null) error!,
        ].join(': '),
      if (!ok && errorCode == null && error == null) 'The workspace refused.',
    ];
    return parts.join('\n');
  }

  String get summary {
    if (ok) {
      if (previewUrl != null) return 'Preview is live on port ${port ?? ''}.';
      if (exitCode != null) return 'Exit 0 in ${_seconds(durationSeconds)}.';
      return 'Done.';
    }
    if (timedOut) return 'Timed out after ${_seconds(durationSeconds)}.';
    if (exitCode != null) {
      return 'Exit $exitCode in ${_seconds(durationSeconds)}.';
    }
    return error ?? errorCode ?? 'The workspace refused.';
  }

  static String _seconds(double? value) =>
      value == null ? 'unknown time' : '${value.toStringAsFixed(1)}s';
}

/// What a read of one file answered.
class WorkspaceFileContent {
  const WorkspaceFileContent({
    required this.path,
    required this.content,
    this.truncated = false,
  });

  final String path;
  final String content;
  final bool truncated;

  factory WorkspaceFileContent.fromJson(Map<String, dynamic> json) =>
      WorkspaceFileContent(
        path: (json['path'] as String?) ?? '',
        content: (json['content'] as String?) ?? '',
        truncated: _flag(json['truncated']),
      );
}

Map<String, dynamic> _section(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
int? _int(Object? value) => value is int ? value : null;
String? _optionalString(Object? value) => value is String ? value : null;
bool? _optionalBool(Object? value) => value is bool ? value : null;
List<String>? _optionalStringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : null;

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
