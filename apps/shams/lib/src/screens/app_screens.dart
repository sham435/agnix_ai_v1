import 'package:flutter/material.dart';

import '../api/models.dart';

/// Sign-in form for the Rails v1 session endpoint.
///
/// Mirrors the `login` screen of `mobile/App.tsx`: two fields, one submit
/// action, and the server's own error text surfaced verbatim.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    required this.onSubmit,
    super.key,
    this.busy = false,
    this.error,
    this.origin,
  });

  /// Called with the trimmed credentials; the caller owns the request.
  final Future<void> Function(String email, String password) onSubmit;
  final bool busy;
  final String? error;
  final String? origin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty || widget.busy) return;
    await widget.onSubmit(email, password);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 40,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'Shams',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.origin != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.origin!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                TextField(
                  controller: _email,
                  enabled: !widget.busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !widget.busy,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: widget.busy ? null : _submit,
                  child: widget.busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in'),
                ),
                if (widget.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    widget.error!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The signed-in landing screen: active conversations and organization agents.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.conversations,
    required this.agents,
    required this.onRefresh,
    required this.onLogout,
    super.key,
    this.origin,
  });

  final List<Conversation> conversations;
  final List<Agent> agents;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLogout;
  final String? origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shams'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (origin != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Connected to $origin',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            _SectionHeader(title: 'Conversations', count: conversations.length),
            if (conversations.isEmpty)
              const _EmptyHint('No active conversations yet.'),
            for (final conversation in conversations)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text(conversation.displayName),
                subtitle: Text(conversation.agent?.name ?? conversation.status),
              ),
            _SectionHeader(title: 'Agents', count: agents.length),
            if (agents.isEmpty) const _EmptyHint('No agents in this space.'),
            for (final agent in agents)
              ListTile(
                leading: Icon(
                  agent.isActive ? Icons.smart_toy_outlined : Icons.smart_toy,
                ),
                title: Text(agent.name),
                subtitle: Text(agent.subtitle),
                trailing: agent.isActive
                    ? null
                    : const Icon(Icons.pause_circle_outline, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}
