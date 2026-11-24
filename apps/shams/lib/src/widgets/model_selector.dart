import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/shams_api.dart';

/// Catalogue state is scoped to the chat, not the agent or organization.
class ModelSelector extends StatefulWidget {
  const ModelSelector({
    super.key,
    required this.api,
    required this.conversationId,
    this.enabled = true,
    this.fallbackLabel,
  });
  final ShamsApi api;
  final String conversationId;
  final bool enabled;
  final String? fallbackLabel;
  @override
  State<ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<ModelSelector> {
  ModelCatalogue? _catalogue;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ModelSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.api != widget.api) {
      _catalogue = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final result = await widget.api.modelCatalogue(widget.conversationId);
      if (mounted && generation == _generation) {
        setState(() => _catalogue = result);
      }
    } catch (_) {
      // The sheet offers a retry and the actual failure; chat remains usable.
    }
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Choose chat model',
    child: InkWell(
      onTap: widget.enabled
          ? () async {
              final generation = _generation;
              final result = await showModalBottomSheet<ModelCatalogue>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => ModelSelectionSheet(
                  api: widget.api,
                  conversationId: widget.conversationId,
                  initial: _catalogue,
                ),
              );
              if (mounted && generation == _generation && result != null) {
                setState(() => _catalogue = result);
              }
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text(
          _catalogue == null && widget.fallbackLabel != null
              ? widget.fallbackLabel!
              : '${_catalogue?.selectionLabel ?? 'Choose model'} ▾',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

class ModelSelectionSheet extends StatefulWidget {
  const ModelSelectionSheet({
    super.key,
    required this.api,
    required this.conversationId,
    this.initial,
  });
  final ShamsApi api;
  final String conversationId;
  final ModelCatalogue? initial;
  @override
  State<ModelSelectionSheet> createState() => _ModelSelectionSheetState();
}

class _ModelSelectionSheetState extends State<ModelSelectionSheet> {
  ModelCatalogue? _catalogue;
  bool _busy = false;
  String? _error;
  String _query = '';
  @override
  void initState() {
    super.initState();
    _catalogue = widget.initial;
    _request(() => widget.api.modelCatalogue(widget.conversationId));
  }

  Future<void> _request(
    Future<ModelCatalogue> Function() action, {
    bool close = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() => _catalogue = result);
      if (close) Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.unauthorized
              ? 'Your session has ended. Sign in again.'
              : error.message,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to reach the model catalogue. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _capability(String name, bool? value) =>
      '$name: ${value == null
          ? 'unknown'
          : value
          ? 'yes'
          : 'no'}';

  String _providerStatusLabel(CatalogueProvider provider) =>
      switch (provider.readiness) {
        'billing_blocked' =>
          'Billing blocked: provider credits are insufficient',
        'inference_ready' => 'Inference ready: a real request succeeded',
        'catalogue_available' =>
          'Catalogue available: inference unverified',
        'access_restricted' =>
          'Access restricted: provider or model access is limited',
        'configuration_invalid' =>
          'Configuration invalid: check provider settings',
        'connected' => 'Connected: credentials configured',
        'disabled' => 'Paused',
        'unavailable' => 'Unavailable',
        _ => provider.readiness.isNotEmpty
            ? provider.readiness
            : provider.connectionStatus.isNotEmpty
            ? provider.connectionStatus
            : 'Provider status unknown',
      };

  String _availabilityLabel(String status) => switch (status) {
    'available' => 'Available',
    'disabled' => 'Disabled',
    'retired' => 'Retired',
    'access_restricted' => 'Access restricted',
    'unavailable' => 'Unavailable',
    '' => 'Availability unknown',
    _ => status,
  };

  String _inferenceStatusLabel(CatalogueModel model) {
    final status = model.inferenceStatus;
    if (status == null || status.isEmpty) return 'Inference status unknown';
    final verifiedAt = model.inferenceVerifiedAt;
    final attemptedAt = model.lastInferenceAttemptAt;
    final errorCode = model.lastInferenceErrorCode;
    return switch (status) {
      'verified' => verifiedAt == null
          ? 'Inference verified'
          : 'Inference verified: ${verifiedAt.toLocal()}',
      'unverified' => attemptedAt == null
          ? 'Inference unverified'
          : 'Inference unverified · Last attempt: ${attemptedAt.toLocal()}',
      'failed' => [
        'Inference failed',
        if (attemptedAt != null) 'Last attempt: ${attemptedAt.toLocal()}',
        if (errorCode != null && errorCode.isNotEmpty) errorCode,
      ].join(' · '),
      'billing_blocked' => 'Inference blocked: provider credits insufficient',
      'access_restricted' => 'Inference access restricted',
      'configuration_invalid' => 'Inference configuration invalid',
      _ => 'Inference: $status',
    };
  }

  String _tokenCount(int value) {
    if (value >= 1000000) {
      final count = value / 1000000;
      return '${count.toStringAsFixed(count % 1 == 0 ? 0 : 1)}M';
    }
    if (value >= 1000) {
      final count = value / 1000;
      return '${count.toStringAsFixed(count % 1 == 0 ? 0 : 1)}K';
    }
    return '$value';
  }

  String _modelMetadata(CatalogueModel model) {
    final parts = <String>[
      if (model.apiFamily?.isNotEmpty ?? false) 'API: ${model.apiFamily}',
      if (model.contextWindow != null)
        'Context: ${_tokenCount(model.contextWindow!)}',
      if (model.maxOutputTokens != null)
        'Max output: ${_tokenCount(model.maxOutputTokens!)}',
      if (model.freeTier == true) 'Free tier',
      if (model.local == true) 'Local',
      if (model.isDefault == true) 'Organization default',
    ];
    final limits = model.rateLimits.entries
        .where(
          (entry) =>
              entry.value is num ||
              entry.value is bool ||
              entry.value is String,
        )
        .take(3)
        .map(
          (entry) => '${entry.key.replaceAll('_', ' ')}: ${entry.value}',
        )
        .join(' · ');
    if (limits.isNotEmpty) parts.add('Limits: $limits');
    return parts.join(' · ');
  }

  String _modelCapabilities(CatalogueModel model) => [
    _capability('Tools', model.supportsTools),
    _capability('Vision', model.supportsVision),
    _capability('Streaming', model.supportsStreaming),
    if (model.supportsImages == true) 'Images: yes',
    if (model.supportsJsonMode == true) 'JSON mode: yes',
    if (model.supportsReasoning == true) 'Reasoning: yes',
    if (model.supportsParallelToolCalls == true) 'Parallel tools: yes',
  ].join(' · ');

  String _modelSubtitle(CatalogueModel model) {
    final metadata = _modelMetadata(model);
    return [
      model.modelId,
      '${_availabilityLabel(model.availabilityStatus)} · ${_inferenceStatusLabel(model)}',
      if (metadata.isNotEmpty) metadata,
      _modelCapabilities(model),
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = _catalogue;
    final groups = <String, String>{
      for (final provider in catalogue?.providers ?? <CatalogueProvider>[])
        provider.providerId: provider.providerName,
      for (final model in catalogue?.models ?? <CatalogueModel>[])
        model.providerId: model.providerName,
    };
    final matches = (catalogue?.models ?? <CatalogueModel>[])
        .where(
          (model) =>
              '${model.label} ${model.modelId} ${model.providerName} ${model.providerId}'
                  .toLowerCase()
                  .contains(_query),
        )
        .toList();
    return PopScope(
      canPop: !_busy,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Chat model')),
                  IconButton(
                    tooltip: 'Refresh models',
                    onPressed: _busy
                        ? null
                        : () => _request(
                            () =>
                                widget.api.refreshModels(widget.conversationId),
                          ),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(catalogue),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text(
                'Availability and inference status are reported separately.',
              ),
              if (catalogue?.updatedAt != null)
                Text('Updated: ${catalogue!.updatedAt!.toLocal()}'),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search models',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _request(
                              () => widget.api.modelCatalogue(
                                widget.conversationId,
                              ),
                            ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ListTile(
                title: const Text('Use organization default'),
                subtitle: Text(
                  catalogue?.defaultModel?.modelId ?? 'No default configured',
                ),
                trailing: catalogue != null && catalogue.selectedModel == null
                    ? const Icon(Icons.check)
                    : null,
                onTap: _busy || catalogue == null
                    ? null
                    : () => _request(
                        () => widget.api.selectConversationModel(
                          widget.conversationId,
                          null,
                        ),
                        close: true,
                      ),
              ),
              if (catalogue?.selectedModel != null &&
                  !catalogue!.models.any(
                    (model) => model.matches(catalogue.selectedModel),
                  ))
                Text(
                  'Selected: ${catalogue.selectedModel!.providerId} / ${catalogue.selectedModel!.modelId} (not in catalogue)',
                ),
              Expanded(
                child: ListView(
                  children: [
                    if (!_busy && matches.isEmpty)
                      const ListTile(title: Text('No matching models.')),
                    for (final group in groups.entries) ...[
                      if (matches.any(
                            (model) => model.providerId == group.key,
                          ) ||
                          _query.isEmpty) ...[
                        ListTile(
                          title: Text(
                            group.value.isEmpty ? group.key : group.value,
                          ),
                          subtitle: Text(
                            [
                              for (final provider
                                  in catalogue?.providers ??
                                      <CatalogueProvider>[])
                                if (provider.providerId == group.key)
                                  '${_providerStatusLabel(provider)}${provider.errorCode == null ? '' : ' · ${provider.errorCode}'}',
                            ].join(' · '),
                          ),
                        ),
                        for (final model in matches.where(
                          (model) => model.providerId == group.key,
                        ))
                          ListTile(
                            title: Text(model.label),
                            subtitle: Text(_modelSubtitle(model)),
                            isThreeLine: true,
                            trailing: model.matches(catalogue?.effectiveModel)
                                ? const Icon(Icons.check)
                                : null,
                            enabled: !_busy && model.selectable,
                            onTap: () => _request(
                              () => widget.api.selectConversationModel(
                                widget.conversationId,
                                model,
                              ),
                              close: true,
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
