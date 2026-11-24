import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/shams_api.dart';

/// The Coding Workspace as its own screen - the mobile counterpart of the
/// web's right-side panel, reading the same endpoints.
///
/// Everything drawn here is the server's answer. The container's state comes
/// from the manager (`status`), the project files from the sandbox itself, and
/// a refusal carries the manager's own words and code. Nothing is simulated,
/// and nothing that did not happen is reported as having worked: a command
/// that the workspace refused shows the refusal, and a sandbox that was never
/// started says so instead of drawing an empty file list as if it were a
/// project with no files.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({required this.api, this.conversationId, super.key});

  final ShamsApi api;

  /// The thread this screen was opened from.
  ///
  /// A workspace is the sandbox a conversation's coding turns ran in, and a
  /// conversation is the only thing a user can name - so this is how the screen
  /// finds its own. Without it, the account's newest workspace is shown.
  final String? conversationId;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  static const _tabLabels = <String>[
    'Files',
    'Terminal',
    'Tests',
    'Preview',
    'Logs',
  ];

  late final TabController _tabs = TabController(
    length: _tabLabels.length,
    vsync: this,
  );

  final _command = TextEditingController();
  final _port = TextEditingController(text: '8000');

  /// The snapshot from `GET /api/v1/workspaces/:id` - the row, the manager's
  /// state, the files and the run history. Null until a read brought one, and
  /// null forever when this conversation has never run any code.
  Workspace? _workspace;

  /// Whether the first read finished, so "no workspace" is a fact rather than
  /// a spinner that has not resolved yet.
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  /// The open file, or null while the listing shows. This is client state: the
  /// content is what this client read, not part of the snapshot.
  WorkspaceFileContent? _file;

  /// What each tab's last call answered, kept apart so a test run's output
  /// never shows up as terminal output.
  WorkspaceActionResult? _terminal;
  WorkspaceActionResult? _tests;
  WorkspaceActionResult? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _command.dispose();
    _port.dispose();
    super.dispose();
  }

  /// Read the account's (or this conversation's) workspaces, keep the one this
  /// screen already had, and load its snapshot.
  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    Workspace? next;
    String? failure;
    try {
      final workspaces = await widget.api.listWorkspaces(
        conversationId: widget.conversationId,
      );
      final keep = _workspace?.id;
      var chosen = workspaces.isEmpty ? null : workspaces.first;
      for (final candidate in workspaces) {
        if (candidate.id == keep) {
          chosen = candidate;
          break;
        }
      }
      if (chosen != null) next = await widget.api.workspace(chosen.id);
    } on ApiException catch (error) {
      failure = _words(error);
    }

    if (!mounted) return;
    setState(() {
      _workspace = next;
      _loaded = true;
      _busy = false;
      _error = failure;
    });
  }

  /// Run one action, remember its answer in [into], then read the snapshot
  /// again - the screen's state is what the server says it is now, including
  /// after a refusal.
  ///
  /// A refusal is an answer, not an exception: `[WorkspaceActionResult]`
  /// carries the manager's own `error_code` and reason, which is what gets
  /// shown. [announceOnFailure] is for the actions whose answer has no tab to
  /// print it in - stopping the workspace - so their reason is never dropped.
  Future<void> _act(
    Future<WorkspaceActionResult> Function() action, {
    void Function(WorkspaceActionResult?)? into,
    bool announceOnFailure = false,
  }) async {
    if (_busy) return;
    WorkspaceActionResult? result;
    String? failure;

    setState(() => _busy = true);
    try {
      result = await action();
    } on ApiException catch (error) {
      failure = _words(error);
    }
    if (!mounted) return;
    if (into != null) into(result);

    await _load();
    if (!mounted) return;
    if (failure != null) {
      _report(failure);
    } else if (announceOnFailure && result != null && !result.ok) {
      _report(result.transcript);
    }
  }

  Future<void> _openFile(WorkspaceFile file) async {
    if (_busy) return;
    final workspace = _workspace;
    if (workspace == null) return;

    setState(() {
      _busy = true;
      _file = null;
    });
    try {
      final content = await widget.api.readWorkspaceFile(
        workspace.id,
        file.path,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _file = content;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _report(_words(error));
    }
  }

  Future<void> _stopWorkspace() async {
    final workspace = _workspace;
    if (workspace == null || _busy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop "${workspace.name}"?'),
        content: const Text(
          'The container is removed and the workspace stops answering. Its '
          'files and run history stay readable, and the next coding turn in '
          'the chat starts a fresh sandbox.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it running'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop workspace'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _act(
      () => widget.api.stopWorkspace(workspace.id),
      announceOnFailure: true,
    );
  }

  /// Where a refusal is shown. A screen that has data reports in a snack bar,
  /// because the failure is about one step, not about the whole read.
  void _report(String words) {
    if (_workspace == null) {
      setState(() => _error = words);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(words),
        showCloseIcon: true,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  String _words(ApiException error) => error.unauthorized
      ? 'Your session has ended. Sign in again.'
      : error.message;

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    return Scaffold(
      appBar: AppBar(
        title: Text(workspace?.name ?? 'Coding Workspace'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          if (workspace != null && !workspace.isStopped)
            IconButton(
              tooltip: 'Stop workspace',
              onPressed: _busy ? null : _stopWorkspace,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _Problem(message: _error!),
            ),
          if (workspace == null)
            Expanded(
              child: _NotThere(
                loading: !_loaded && _busy,
                busy: _busy,
                onRetry: _load,
                fromConversation: widget.conversationId != null,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _StatusCard(workspace: workspace),
            ),
            TabBar(
              controller: _tabs,
              isScrollable: _tabLabels.length > 4,
              tabs: [
                for (final label in _tabLabels)
                  Tab(child: Text(label, style: const TextStyle(fontSize: 13))),
              ],
            ),
            Expanded(
              child: _busy && !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        _filesTab(workspace),
                        _terminalTab(workspace),
                        _testsTab(workspace),
                        _previewTab(workspace),
                        _logsTab(workspace),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filesTab(Workspace workspace) {
    final theme = Theme.of(context);
    final file = _file;

    if (file != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'All files',
                  onPressed: () => setState(() => _file = null),
                  icon: const Icon(Icons.folder_outlined),
                ),
                Expanded(
                  child: Text(
                    file.path,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (file.truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'The server sent only the start of this file.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: SelectableText(
                file.content.isEmpty ? '(empty)' : file.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['monospace'],
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (workspace.filesError != null && workspace.files.isEmpty) {
      return _Notice(
        // An unreachable manager is a fact to report, never an empty project.
        text: 'The files could not be listed: ${workspace.filesError}',
        busy: _busy,
        onRetry: _load,
      );
    }
    if (workspace.isStopped) {
      return _Notice(text: _stoppedWords, busy: _busy, onRetry: _load);
    }
    if (workspace.files.isEmpty) {
      return _Notice(
        text:
            'The sandbox has no files yet - they appear once a coding turn '
            'writes something into it.',
        busy: _busy,
        onRetry: _load,
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        children: [
          for (final entry in workspace.files)
            ListTile(
              leading: Icon(
                entry.isText ? Icons.description_outlined : Icons.bolt_outlined,
              ),
              title: Text(entry.path),
              subtitle: Text(entry.sizeLabel),
              trailing: entry.isText
                  ? const Icon(Icons.chevron_right)
                  : const SizedBox.shrink(),
              onTap: _busy || !entry.isText ? null : () => _openFile(entry),
            ),
          if (workspace.filesTruncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Only the first ${workspace.files.length} files are listed.',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _terminalTab(Workspace workspace) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (workspace.isStopped)
          _Transcript(text: _stoppedWords, tone: _Tone.error)
        else ...[
          Text(
            'One command, run as tokens inside the sandbox. There is no shell: '
            'the server splits this line and the container executes it, so a '
            'filename with a space needs no quoting.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _command,
            enabled: !_busy,
            autocorrect: false,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              labelText: 'Command',
              hintText: 'python3 -V',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_terminal != null) setState(() => _terminal = null);
            },
            onSubmitted: (_) => _runCommand(),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _runCommand,
            icon: const Icon(Icons.play_arrow),
            label: Text(_busy ? 'Running…' : 'Run'),
          ),
        ],
        const SizedBox(height: 16),
        if (_terminal != null) ...[
          _Summary(result: _terminal!),
          const SizedBox(height: 8),
          _Transcript(text: _terminal!.transcript, tone: _Tone.output),
          const SizedBox(height: 16),
        ],
        for (final run in workspace.runs.where((run) => run.kind == 'exec'))
          _RunBlock(run: run),
        if (workspace.runs.where((run) => run.kind == 'exec').isEmpty &&
            _terminal == null &&
            !workspace.isStopped)
          Text(
            'No command has been run from this screen.',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  void _runCommand() {
    final workspace = _workspace;
    final line = _command.text.trim();
    if (workspace == null || line.isEmpty || _busy) return;
    _act(
      () => widget.api.runWorkspaceCommand(workspace.id, command: line),
      into: (result) => _terminal = result,
    );
  }

  Widget _testsTab(Workspace workspace) {
    final theme = Theme.of(context);
    final testRuns = workspace.runs.where((run) => run.kind == 'test');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(
          'The test command the provider chose for this runtime, run inside '
          'the same sandbox as the project.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: workspace.isStopped || _busy
              ? null
              : () => _act(
                  () => widget.api.runWorkspaceTests(workspace.id),
                  into: (result) => _tests = result,
                ),
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(_busy ? 'Running…' : 'Run tests'),
        ),
        if (workspace.isStopped) ...[
          const SizedBox(height: 12),
          _Transcript(text: _stoppedWords, tone: _Tone.error),
        ],
        const SizedBox(height: 16),
        if (_tests != null) ...[
          _Summary(result: _tests!),
          const SizedBox(height: 8),
          _Transcript(text: _tests!.transcript, tone: _Tone.output),
          const SizedBox(height: 16),
        ],
        for (final run in testRuns) _RunBlock(run: run),
        if (testRuns.isEmpty && _tests == null)
          Text(
            'No test run is recorded for this workspace yet.',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  Widget _previewTab(Workspace workspace) {
    final theme = Theme.of(context);
    final link = workspace.preview;
    final result = _preview;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(
          'A preview is served by the sandbox and reached through this '
          'installation\'s gateway with a link that expires. The link is for '
          'the browser at ${widget.api.origin}.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (workspace.isStopped)
          _Transcript(text: _stoppedWords, tone: _Tone.error)
        else ...[
          TextField(
            controller: _port,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Port',
              helperText: '1024-65535',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _startPreview(workspace),
                child: const Text('Start preview'),
              ),
              const SizedBox(width: 10),
              if (link != null && link.isLive)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _act(
                          () => widget.api.stopWorkspacePreview(workspace.id),
                          into: (result) => _preview = result,
                        ),
                  child: const Text('Stop preview'),
                ),
            ],
          ),
        ],
        if (result != null) ...[
          const SizedBox(height: 12),
          _Summary(result: result),
          if (result.transcript.isNotEmpty)
            _Transcript(text: result.transcript, tone: _Tone.output),
        ],
        const SizedBox(height: 16),
        if (link != null && link.isLive) ...[
          Text('Preview link', style: theme.textTheme.labelLarge),
          SelectableText(
            '${widget.api.origin}${link.url}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['monospace'],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Port ${link.port} · ${link.lifetimeLabel}',
            style: theme.textTheme.bodySmall,
          ),
        ] else if (!workspace.isStopped)
          Text(
            'No preview is running for this workspace.',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  void _startPreview(Workspace workspace) {
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      _report('Enter the port number the app listens on, for example 8000.');
      return;
    }
    _act(
      () => widget.api.startWorkspacePreview(workspace.id, port: port),
      into: (result) => _preview = result,
    );
  }

  Widget _logsTab(Workspace workspace) {
    final theme = Theme.of(context);
    if (workspace.runs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Text(
          'Nothing has run in this workspace yet. The steps an agent takes - '
          'commands, installs, tests, exports - are recorded here.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          for (final run in workspace.runs) ...[
            _RunBlock(run: run),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  static const _stoppedWords =
      'This workspace has been stopped. Its history stays readable, but code '
      'cannot run in it; start a new turn in the chat to get a fresh sandbox.';
}

/// The row the screen always shows: what the account's row says and, next to
/// it, what the manager says about the container right now.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(workspace.name, style: theme.textTheme.titleMedium),
              ),
              _Chip(
                label: workspace.statusLabel,
                positive: workspace.isRunning,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              'Runtime ${workspace.runtime}',
              if (workspace.container != null) workspace.container!,
              if (workspace.runtimeStatus == 'unavailable')
                'manager not answering',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          if (workspace.lastError != null) ...[
            const SizedBox(height: 6),
            Text(
              workspace.lastError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.positive});

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = positive
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

enum _Tone { output, error }

/// A block of what the sandbox printed, in the server's own words.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.text, required this.tone});

  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final error = tone == _Tone.error;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: error
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['monospace'],
          color: error ? theme.colorScheme.onErrorContainer : null,
        ),
      ),
    );
  }
}

/// One step's result, worded from the server's verdict only.
class _Summary extends StatelessWidget {
  const _Summary({required this.result});

  final WorkspaceActionResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      result.summary,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: result.ok ? null : theme.colorScheme.error,
      ),
    );
  }
}

/// One recorded run, with whatever it printed.
class _RunBlock extends StatelessWidget {
  const _RunBlock({required this.run});

  final WorkspaceRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final output = run.output;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              run.ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 16,
              color: run.ok
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(run.title, style: theme.textTheme.bodyMedium)),
            if (run.durationMs != null)
              Text(
                '${(run.durationMs! / 1000).toStringAsFixed(1)}s',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
        Text(
          '${run.kind}${run.timedOut ? ' · timed out' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        if (output.isNotEmpty) _Transcript(text: output, tone: _Tone.output),
      ],
    );
  }
}

/// A fact about the workspace that is not an error in itself - an empty
/// project, a stopped sandbox, a manager that would not answer.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.text,
    required this.busy,
    required this.onRetry,
  });

  final String text;
  final bool busy;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        Text(text, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: busy ? null : onRetry,
            child: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}

/// This conversation has no sandbox to show - because no coding turn has run
/// in it, which is the server's fact and not this client's guess.
class _NotThere extends StatelessWidget {
  const _NotThere({
    required this.loading,
    required this.busy,
    required this.onRetry,
    required this.fromConversation,
  });

  final bool loading;
  final bool busy;
  final Future<void> Function() onRetry;
  final bool fromConversation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
      children: [
        Text(
          fromConversation
              ? 'This conversation has not run any code yet.'
              : 'This account has no workspace yet.',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'A workspace is created the first time a coding turn writes a file '
          'or runs a command in the sandbox. Ask for that in the chat and '
          'return here.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: busy ? null : onRetry,
            child: const Text('Check again'),
          ),
        ),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}
