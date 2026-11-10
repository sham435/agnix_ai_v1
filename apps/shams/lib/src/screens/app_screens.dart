import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/theme_controller.dart';
import '../widgets/brand_mark.dart';
import '../widgets/prompt_card.dart';
import '../widgets/theme_button.dart';

/// Beyond this width the home screen switches from the phone layout (stacked
/// list + drawer) to the desktop shell (sidebar + content pane). Chosen above
/// the default test surface (800) so fixture-driven tests exercise the exact
/// phone layout they were written against.
const double desktopBreakpoint = 1000;

/// Widths of the collapsible desktop sidebar.
const double _sidebarExpandedWidth = 280;
const double _sidebarCollapsedWidth = 68;

/// Sign-in form for the Rails v1 session endpoint.
///
/// Mirrors the `login` screen of `mobile/App.tsx`: two fields, one submit
/// action, and the server's own error text surfaced verbatim. The brand
/// identity is the shared [BrandMark]/[BrandWordmark], not bespoke art.
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
      body: Stack(
        children: [
          const Positioned(top: 12, right: 12, child: ThemeButton()),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(child: BrandMark(size: 44)),
                    const SizedBox(height: 12),
                    const Align(child: BrandWordmark(fontSize: 26)),
                    if (widget.origin != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.origin!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                    const SizedBox(height: 28),
                    // The fields pick up the filled, rounded input theme; the
                    // floating labels are the only per-field addition.
                    TextField(
                      controller: _email,
                      enabled: !widget.busy,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      enabled: !widget.busy,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration:
                          const InputDecoration(labelText: 'Password'),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: widget.busy ? null : _submit,
                      child: widget.busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
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
        ],
      ),
    );
  }
}

/// The signed-in landing screen: active conversations and organization agents.
///
/// Phone layout: app bar + scrollable sections + drawer + new-chat FAB.
/// Desktop layout ([desktopBreakpoint] and wider): a collapsible left sidebar
/// with the same lists, plus a content pane hosting the welcome surface. Both
/// share [_NavSections] and [WelcomeSurface], so the two layouts are one
/// visual system rather than two implementations.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.conversations,
    required this.agents,
    required this.onRefresh,
    required this.onLogout,
    required this.onOpenConversation,
    required this.onNewChat,
    required this.onChatWithAgent,
    required this.onSuggestion,
    super.key,
    this.origin,
  });

  final List<Conversation> conversations;
  final List<Agent> agents;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLogout;

  /// Opens an existing thread.
  final void Function(Conversation conversation) onOpenConversation;

  /// Offers the agent list and starts a conversation with the chosen one.
  final Future<void> Function() onNewChat;

  /// Starts a conversation with a specific agent - the Agents section is the
  /// natural place to pick a model, since the model lives on the agent.
  final Future<void> Function(Agent agent) onChatWithAgent;

  /// A welcome prompt card was tapped: the same agent choice, then the thread
  /// starts with the prompt as its first turn.
  final Future<void> Function(String prompt) onSuggestion;

  final String? origin;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= desktopBreakpoint
              ? _DesktopShell(this)
              : _PhoneHome(this),
    );
  }
}

/// The phone layout. Structure and strings match what the fixtures expect:
/// "CONVERSATIONS"/"AGENTS" headers, `displayName` rows, the "New chat" FAB
/// and the logout icon in the app bar.
class _PhoneHome extends StatefulWidget {
  const _PhoneHome(this.screen);

  final HomeScreen screen;

  @override
  State<_PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<_PhoneHome> {
  /// The Scaffold this state builds; the menu opens the drawer through it
  /// (`Scaffold.of` cannot see the Scaffold from the build context that
  /// *returns* it, so the key is the one way in).
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The drawer is built lazily: a closed drawer's contents stay in the
  /// element tree (offstage), and eagerly building the lists there would
  /// duplicate the conversation rows the fixtures tap. The first menu tap
  /// builds the drawer and opens it on the following frame.
  bool _drawerReady = false;

  void _openDrawerFromMenu() {
    setState(() => _drawerReady = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scaffoldKey.currentState?.openDrawer();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.screen;
    final theme = Theme.of(context);
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Conversations and agents',
          onPressed: _openDrawerFromMenu,
          icon: const Icon(Icons.menu),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 26),
            const SizedBox(width: 8),
            // Flexible: the middle toolbar slot is whatever the app bar's
            // other controls leave; a fixed string cannot overflow it.
            Flexible(
              child: Text(
                'Shams',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          const ThemeButton(),
          IconButton(
            tooltip: 'Sign out',
            onPressed: screen.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      drawer: _drawerReady
          ? _HomeDrawer(screen: screen)
          : Drawer(
              // Placeholder shell, filled on first open. The placeholder exists
              // only so `Scaffold.of(context).openDrawer()` has a drawer to
              // open; the swap happens before that call.
              backgroundColor: theme.colorScheme.surface,
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: screen.onNewChat,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New chat'),
      ),
      body: RefreshIndicator(
        onRefresh: screen.onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: [
            if (screen.origin != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text(
                  'Connected to ${screen.origin}',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            if (screen.conversations.isEmpty) WelcomeSurface(screen: screen),
            _SectionHeader(
              title: 'Conversations',
              count: screen.conversations.length,
            ),
            if (screen.conversations.isEmpty)
              const _EmptyHint('No active conversations yet.'),
            for (final conversation in screen.conversations)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text(conversation.displayName),
                subtitle: Text(conversation.agent?.name ?? conversation.status),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => screen.onOpenConversation(conversation),
              ),
            _SectionHeader(title: 'Agents', count: screen.agents.length),
            if (screen.agents.isEmpty)
              const _EmptyHint('No agents in this space.'),
            for (final agent in screen.agents)
              ListTile(
                leading: Icon(
                  agent.isActive ? Icons.smart_toy_outlined : Icons.smart_toy,
                ),
                title: Text(agent.name),
                subtitle: Text(agent.subtitle),
                trailing: agent.isActive
                    ? null
                    : const Icon(Icons.pause_circle_outline, size: 18),
                onTap: () => screen.onChatWithAgent(agent),
              ),
          ],
        ),
      ),
    );
  }
}

/// The desktop shell: collapsible sidebar + content pane.
///
/// The sidebar carries the same sections as the phone list, collapses to icon
/// width, and the content pane is the welcome surface with the prompt cards -
/// threads open through the same full-screen route the phone pushes.
class _DesktopShell extends StatelessWidget {
  const _DesktopShell(this.screen);

  final HomeScreen screen;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Sidebar(screen: screen),
        Expanded(child: _DesktopMainPane(screen: screen)),
      ],
    );
  }
}

/// One sidebar/drawer navigation body: conversations and agents. Both hosts
/// close themselves ([onTap]) before routing onward, so the drawer version
/// does not leave a stale shade over the pushed screen.
class _NavSections extends StatelessWidget {
  const _NavSections({required this.screen, required this.onTap});

  final HomeScreen screen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Conversations',
          count: screen.conversations.length,
        ),
        if (screen.conversations.isEmpty)
          const _EmptyHint('No active conversations yet.'),
        for (final conversation in screen.conversations)
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: Text(conversation.displayName),
            subtitle: Text(conversation.agent?.name ?? conversation.status),
            onTap: () {
              onTap();
              screen.onOpenConversation(conversation);
            },
          ),
        _SectionHeader(title: 'Agents', count: screen.agents.length),
        if (screen.agents.isEmpty) const _EmptyHint('No agents in this space.'),
        for (final agent in screen.agents)
          ListTile(
            leading: Icon(
              agent.isActive ? Icons.smart_toy_outlined : Icons.smart_toy,
            ),
            title: Text(agent.name),
            subtitle: Text(agent.subtitle),
            onTap: () {
              onTap();
              screen.onChatWithAgent(agent);
            },
          ),
      ],
    );
  }
}

/// The phone drawer.
class _HomeDrawer extends StatelessWidget {
  const _HomeDrawer({required this.screen});

  final HomeScreen screen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  const BrandMark(size: 30),
                  const SizedBox(width: 10),
                  const BrandWordmark(fontSize: 18),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  _NavSections(
                    screen: screen,
                    onTap: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const ThemeButton(),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: screen.onLogout,
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// The collapsible desktop sidebar: brand, new chat, the lists, then theme and
/// sign out in the footer. Collapsing keeps every row as an icon-affordance
/// host (New chat stays a real button, just icon-only).
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.screen});

  final HomeScreen screen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return _CollapsingSidebar(
      reducedMotion: reduceMotion,
      // A Material under the whole sidebar: the ListTiles paint their ink on
      // the nearest Material ancestor, and the pane's plain Container would
      // otherwise leave them without one.
      builder: (context, collapsed, toggle) => Material(
        type: MaterialType.canvas,
        color: scheme.surface,
        child: Column(
          children: [
            Padding(
              // Collapsed (68 px) has room for one control: the expand toggle
              // becomes the header so nothing can overflow it.
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
              child: collapsed
                  ? IconButton(
                      tooltip: 'Expand sidebar',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: toggle,
                    )
                  : Row(
                      children: [
                        const BrandMark(size: 30),
                        if (!collapsed) ...[
                          const SizedBox(width: 8),
                          const BrandWordmark(fontSize: 18),
                        ],
                        const Spacer(),
                        IconButton(
                          tooltip: 'Collapse sidebar',
                          icon: const Icon(Icons.chevron_left),
                          onPressed: toggle,
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: collapsed
                  ? IconButton.filled(
                      tooltip: 'New chat',
                      icon: const Icon(Icons.add_comment_outlined),
                      onPressed: screen.onNewChat,
                    )
                  : FilledButton.icon(
                      onPressed: screen.onNewChat,
                      icon: const Icon(Icons.add_comment_outlined, size: 18),
                      label: const Text('New chat'),
                    ),
            ),
            Expanded(
              child: collapsed
                  ? const SizedBox.expand()
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [
                        _NavSections(screen: screen, onTap: () {}),
                      ],
                    ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: collapsed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _SidebarThemeCycle(),
                        _SidebarAction(
                          icon: Icons.logout,
                          tooltip: 'Sign out',
                          screen: screen,
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const ThemeButton(),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          onPressed: screen.onLogout,
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('Sign out'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The collapsed sidebar's sign-out icon (the expanded state uses a labelled
/// button; the collapsed one has no room for a label).
class _SidebarAction extends StatelessWidget {
  const _SidebarAction({
    required this.icon,
    required this.tooltip,
    required this.screen,
  });

  final IconData icon;
  final String tooltip;
  final HomeScreen screen;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: screen.onLogout,
      icon: Icon(icon),
    );
  }
}

/// The collapsed sidebar's theme control: cycles
/// system -> light -> dark on each tap.
class _SidebarThemeCycle extends StatelessWidget {
  const _SidebarThemeCycle();

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.of(context);
    return IconButton(
      tooltip: switch (controller.mode) {
        ThemeMode.system => 'Theme: System',
        ThemeMode.light => 'Theme: Light',
        ThemeMode.dark => 'Theme: Dark',
      },
      icon: const Icon(Icons.contrast),
      onPressed: () {
        controller.setMode(
          switch (controller.mode) {
            ThemeMode.system => ThemeMode.light,
            ThemeMode.light => ThemeMode.dark,
            ThemeMode.dark => ThemeMode.system,
          },
        );
      },
    );
  }
}

/// Animates the sidebar's width between expanded and collapsed.
///
/// The resize eases only when the system allows motion; under
/// `prefers-reduced-motion` it is an instant snap = zero duration.
class _CollapsingSidebar extends StatefulWidget {
  const _CollapsingSidebar({
    required this.builder,
    required this.reducedMotion,
  });

  /// Builds the sidebar content for the current state; [toggle] flips it.
  final Widget Function(BuildContext, bool, VoidCallback) builder;
  final bool reducedMotion;

  @override
  State<_CollapsingSidebar> createState() => _CollapsingSidebarState();
}

class _CollapsingSidebarState extends State<_CollapsingSidebar> {
  bool _collapsed = false;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  @override
  Widget build(BuildContext context) {
    // Rebuild on collapse, not on every frame: the AnimatedContainer does its
    // own easing between the widths, with no controller to dispose.
    return AnimatedContainer(
      duration: widget.reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      width: _collapsed ? _sidebarCollapsedWidth : _sidebarExpandedWidth,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
      child: widget.builder(context, _collapsed, _toggle),
    );
  }
}

/// The desktop content pane: the welcome surface plus the conversation list.
class _DesktopMainPane extends StatelessWidget {
  const _DesktopMainPane({required this.screen});

  final HomeScreen screen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: screen.onRefresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
            children: [
              WelcomeSurface(screen: screen, wide: true),
              _SectionHeader(
                title: 'Conversations',
                count: screen.conversations.length,
              ),
              if (screen.conversations.isEmpty)
                const _EmptyHint('No active conversations yet.'),
              for (final conversation in screen.conversations)
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: Text(conversation.displayName),
                  subtitle:
                      Text(conversation.agent?.name ?? conversation.status),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => screen.onOpenConversation(conversation),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The first-use surface: emblem, the exact headline and supporting line from
/// the brief, and the prompt cards.
///
/// On the phone it sits above the (empty) conversation list; on the desktop it
/// is the pane's hero. Every card routes through `HomeScreen.onSuggestion`,
/// which starts a real thread carrying the prompt - nothing is mocked.
class WelcomeSurface extends StatelessWidget {
  const WelcomeSurface({required this.screen, this.wide = false, super.key});

  final HomeScreen screen;

  /// Wider paddings when hosted by the desktop pane.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 560 : 420),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: wide ? 8 : 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(size: 56),
              const SizedBox(height: 16),
              Text(
                'How can I help you today?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(fontSize: 24),
              ),
              const SizedBox(height: 8),
              Text(
                'Your intelligent workspace for thinking, creating and building.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  for (final prompt in promptSuggestions)
                    PromptCard(
                      label: prompt,
                      onSelected: (label) => screen.onSuggestion(label),
                    ),
                ],
              ),
            ],
          ),
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
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text('$count', style: theme.textTheme.labelSmall),
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
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Text(message, style: theme.textTheme.bodySmall),
    );
  }
}
