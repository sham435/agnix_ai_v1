import 'dart:async';

import 'package:flutter/material.dart';

import 'src/api/models.dart';
import 'src/api/shams_api.dart';
import 'src/config.dart';
import 'src/screens/app_screens.dart';
import 'src/screens/chat_screen.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_controller.dart';

void main() {
  runApp(ShamsApp(api: ShamsApi(baseUrl: apiBase)));
}

/// Root of the Shams desktop and Android client.
///
/// Owns the [ThemeController] so the system/light/dark choice made anywhere in
/// the headers is honoured by the whole app; the mode itself is stored in
/// `shared_preferences` by the controller, not here.
class ShamsApp extends StatefulWidget {
  const ShamsApp({required this.api, super.key, this.themeStore});

  final ShamsApi api;

  /// Test seam: injects a store (or none) so widget tests never touch the
  /// platform's real preference persistence.
  final ThemeStore? themeStore;

  @override
  State<ShamsApp> createState() => _ShamsAppState();
}

class _ShamsAppState extends State<ShamsApp> {
  late final ThemeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ThemeController(store: widget.themeStore);
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds MaterialApp whenever the mode changes - the only global rebuild
    // a theme switch legitimately needs.
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => ThemeScope(
        controller: _controller,
        child: MaterialApp(
          title: 'Shams',
          debugShowCheckedModeBanner: false,
          theme: shamsTheme(Brightness.light),
          darkTheme: shamsTheme(Brightness.dark),
          themeMode: _controller.mode,
          home: SessionGate(api: widget.api),
        ),
      ),
    );
  }
}

/// Which screen is showing - the `login | loading | home` states of
/// `mobile/App.tsx`, expressed as an enum.
enum GateStage { loading, signedOut, home }

class SessionGate extends StatefulWidget {
  const SessionGate({required this.api, super.key});

  final ShamsApi api;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  static const _unreachable = 'Cannot reach %s. Is the server running?';

  GateStage _stage = GateStage.loading;
  List<Conversation> _conversations = const <Conversation>[];
  List<Agent> _agents = const <Agent>[];
  String? _error;
  bool _submitting = false;

  String get _origin => widget.api.origin;

  @override
  void initState() {
    super.initState();
    _loadHome();
  }

  @override
  void dispose() {
    widget.api.close();
    super.dispose();
  }

  /// Try to render the workspace; if the API refuses, show the login form.
  Future<void> _loadHome() async {
    if (!mounted) return;
    setState(() => _stage = GateStage.loading);
    try {
      final results = await Future.wait([
        widget.api.listConversations(),
        widget.api.listAgents(),
      ]);
      if (!mounted) return;
      setState(() {
        _conversations = results[0] as List<Conversation>;
        _agents = results[1] as List<Agent>;
        _error = null;
        _stage = GateStage.home;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        // A 401 just means there is no session yet: keep the form clean.
        _error = error.unauthorized ? null : error.message;
        _stage = GateStage.signedOut;
      });
    } on Exception {
      // A transport-level failure (server down, connection refused) also means
      // "not signed in yet" - the same fallback the Expo client uses.
      if (!mounted) return;
      setState(() {
        _error = _unreachable.replaceAll('%s', _origin);
        _stage = GateStage.signedOut;
      });
    }
  }

  Future<void> _signIn(String email, String password) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.fetchCsrfToken();
      await widget.api.login(email, password);
      await _loadHome();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on Exception {
      if (!mounted) return;
      setState(() => _error = _unreachable.replaceAll('%s', _origin));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await widget.api.logout();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
    if (!mounted) return;
    setState(() => _stage = GateStage.signedOut);
  }

  void _openConversation(Conversation conversation, {Agent? seedAgent}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              api: widget.api,
              conversationId: conversation.id,
              title: conversation.displayName,
              agent: seedAgent ?? conversation.effectiveAgent,
            ),
          ),
        )
        .then((_) => _loadHome());
  }

  Future<void> _newChat() async => _chatWithAgent(await _pickAgent());

  /// A prompt card from the welcome surface: choose the agent, then start the
  /// thread *with the prompt as its first turn* - `POST /api/v1/conversations`
  /// accepts optional `content` and runs the whole startup (user row,
  /// `AgentStreamJob`), which is exactly what a suggestion should do. Nothing
  /// here is canned or client-only.
  Future<void> _startFromSuggestion(String prompt) async =>
      _chatWithAgent(await _pickAgent(), content: prompt);

  /// Shows the agent list and returns the choice, or null if backed out.
  ///
  /// Choosing the agent is the model selection: the model lives on the agent
  /// and a conversation's agent cannot be changed afterwards.
  Future<Agent?> _pickAgent() async {
    if (!mounted) return null;
    return pickAgent(context, _agents);
  }

  Future<void> _chatWithAgent(Agent? agent, {String? content}) async {
    if (agent == null) return;

    Conversation created;
    try {
      created = await widget.api.createConversation(
        agentId: agent.id,
        content: content,
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start the chat: ${error.message}')),
      );
      return;
    }

    if (!mounted) return;
    await _loadHome();
    if (!mounted) return;
    _openConversation(created, seedAgent: agent);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_stage) {
      GateStage.loading => _Connecting(origin: _origin),
      GateStage.signedOut => LoginScreen(
        onSubmit: _signIn,
        busy: _submitting,
        error: _error,
        origin: _origin,
      ),
      GateStage.home => HomeScreen(
        conversations: _conversations,
        agents: _agents,
        onRefresh: _loadHome,
        onLogout: _signOut,
        onOpenConversation: _openConversation,
        onNewChat: _newChat,
        onChatWithAgent: _chatWithAgent,
        onSuggestion: _startFromSuggestion,
        origin: _origin,
      ),
    };
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting({required this.origin});

  final String origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Connecting to $origin...', style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
