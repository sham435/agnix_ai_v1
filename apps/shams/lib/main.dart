import 'package:flutter/material.dart';

import 'src/api/models.dart';
import 'src/api/shams_api.dart';
import 'src/config.dart';
import 'src/screens/app_screens.dart';

void main() {
  runApp(ShamsApp(api: ShamsApi(baseUrl: apiBase)));
}

/// Root of the Shams desktop and Android client.
class ShamsApp extends StatelessWidget {
  const ShamsApp({required this.api, super.key});

  final ShamsApi api;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1D4ED8);
    return MaterialApp(
      title: 'Shams',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: SessionGate(api: api),
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
            Text(
              'Connecting to $origin...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
