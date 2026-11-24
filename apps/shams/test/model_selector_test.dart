import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/src/api/models.dart';
import 'package:shams_app/src/api/shams_api.dart';
import 'package:shams_app/src/widgets/model_selector.dart';

import 'fake_transport.dart';

String catalogue({bool selected = false}) => jsonEncode({
  'providers': [
    {
      'provider_id': 'one',
      'provider_name': 'Provider One',
      'connection_status': 'connected',
    },
    {
      'provider_id': 'two',
      'provider_name': 'Provider Two',
      'connection_status': 'failed',
      'error_code': 'discovery_failed',
    },
  ],
  'models': [
    {
      'provider_id': 'one',
      'provider_name': 'Provider One',
      'model_id': 'shared',
      'display_name': 'First model',
      'availability_status': 'available',
      'connection_status': 'connected',
      'inference_status': 'unverified',
      'supports_tools': null,
      'supports_vision': false,
      'supports_streaming': true,
    },
    {
      'provider_id': 'two',
      'provider_name': 'Provider Two',
      'model_id': 'shared',
      'display_name': 'Second model',
      'availability_status': 'unavailable',
      'connection_status': 'failed',
    },
  ],
  'selected_model': selected
      ? {'provider_id': 'one', 'model_id': 'shared'}
      : null,
  'default_model': {'provider_id': 'two', 'model_id': 'shared'},
  'catalogue_updated_at': '2026-11-13T12:00:00Z',
});

void main() {
  test(
    'catalogue preserves unknown capabilities and provider-qualified identity',
    () {
      final parsed = ModelCatalogue.fromJson(
        jsonDecode(catalogue()) as Map<String, dynamic>,
      );
      expect(parsed.models.first.supportsTools, isNull);
      expect(parsed.models.first.supportsVision, false);
      expect(parsed.models.first.supportsStreaming, true);
      expect(parsed.models.first.matches(parsed.defaultModel), false);
      expect(parsed.models.last.matches(parsed.defaultModel), true);
      expect(parsed.models.last.selectable, false);
      expect(parsed.updatedAt, isNotNull);
      expect(ModelCatalogue.fromJson({}).effectiveModel, isNull);
    },
  );

  test(
    'API uses encoded conversation context and existing CSRF transport',
    () async {
      final transport = FakeTransport({
        'GET /api/v1/csrf': [json(200, '{"token":"csrf"}')],
        'GET /api/v1/models': [json(200, catalogue())],
        'POST /api/v1/models/refresh': [json(200, catalogue())],
        'PATCH /api/v1/conversations/chat/model': [
          json(200, catalogue(selected: true)),
          json(200, catalogue()),
        ],
      });
      final api = ShamsApi(
        baseUrl: 'https://example.test',
        transport: transport,
      );
      await api.fetchCsrfToken();
      await api.modelCatalogue('chat & other');
      expect(
        transport.sent.last.uri.queryParameters['conversation_id'],
        'chat & other',
      );
      await api.refreshModels('chat');
      expect(jsonDecode(transport.sent.last.body!), {
        'conversation_id': 'chat',
      });
      final result = await api.selectConversationModel(
        'chat',
        const ModelReference('one', 'shared'),
      );
      expect(result.selectedModel!.providerId, 'one');
      expect(jsonDecode(transport.sent.last.body!), {
        'provider_id': 'one',
        'model_id': 'shared',
      });
      expect(transport.sent.last.headers['X-CSRF-Token'], 'csrf');
      await api.selectConversationModel('chat', null);
      expect(jsonDecode(transport.sent.last.body!), {
        'use_organization_default': true,
      });
    },
  );

  testWidgets(
    'sheet groups, searches, disables unavailable and saves selection',
    (tester) async {
      final transport = FakeTransport({
        'GET /api/v1/models': [json(200, catalogue())],
        'PATCH /api/v1/conversations/chat/model': [
          json(200, catalogue(selected: true)),
        ],
      });
      final api = ShamsApi(
        baseUrl: 'https://example.test',
        transport: transport,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSelector(api: api, conversationId: 'chat'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose chat model'));
      await tester.pumpAndSettle();
      expect(find.text('Provider One'), findsOneWidget);
      expect(find.text('Provider Two'), findsOneWidget);
      expect(find.textContaining('Inference unverified'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Second model'),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      final unavailable = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Second model'),
          matching: find.byType(ListTile),
        ),
      );
      expect(unavailable.enabled, false);
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pumpAndSettle();
      expect(find.text('Second model'), findsNothing);
      await tester.tap(find.text('First model'));
      await tester.pumpAndSettle();
      expect(find.text('First model ▾'), findsOneWidget);
      expect(jsonDecode(transport.sent.last.body!), {
        'provider_id': 'one',
        'model_id': 'shared',
      });
    },
  );

  testWidgets(
    'sheet names provider readiness so a connected provider never implies inference',
    (tester) async {
      final body = jsonEncode({
        'providers': [
          {
            'provider_id': 'one',
            'provider_name': 'Provider One',
            'connection_status': 'connected',
            'readiness': 'billing_blocked',
          },
        ],
        'models': [],
        'selected_model': null,
        'default_model': null,
      });
      final transport = FakeTransport({
        'GET /api/v1/models': [json(200, body)],
      });
      final api = ShamsApi(
        baseUrl: 'https://example.test',
        transport: transport,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSelectionSheet(api: api, conversationId: 'chat'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Billing blocked: provider credits are insufficient',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('connected'), findsNothing);
    },
  );

  testWidgets(
    'failed load retries, refreshes and resets conversation default',
    (tester) async {
      final transport = FakeTransport({
        'GET /api/v1/models': [
          json(503, '{"error":"Catalogue unavailable"}'),
          json(200, catalogue(selected: true)),
        ],
        'POST /api/v1/models/refresh': [json(200, catalogue(selected: true))],
        'PATCH /api/v1/conversations/chat/model': [json(200, catalogue())],
      });
      final api = ShamsApi(
        baseUrl: 'https://example.test',
        transport: transport,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSelectionSheet(api: api, conversationId: 'chat'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Catalogue unavailable'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh models'));
      await tester.pumpAndSettle();
      expect(transport.sent.last.method, 'POST');
      await tester.tap(find.text('Use organization default'));
      await tester.pumpAndSettle();
      expect(jsonDecode(transport.sent.last.body!), {
        'use_organization_default': true,
      });
    },
  );
}
