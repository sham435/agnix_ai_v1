class AgentRunner
  # A tool-using chat turn can do multi-step work in an isolated workspace,
  # so the old tight cap of 10 cut off work that was still progressing.
  # Chat gets a moderate budget; a build/OS task, which can legitimately churn
  # through dozens of steps (scaffold files, install dependencies, re-verify),
  # gets a larger one. See #iteration_budget for how they are chosen.
  MAX_ITERATIONS = 20
  BUILD_MAX_ITERATIONS = 30
  MAX_TOOL_CALLS_PER_TURN = 5
  # Context bounding for the tool transcript. #build_messages re-sends every
  # accumulated tool result on every iteration of a multi-step run, so a 5-10
  # file build grows the prompt toward the model's context limit - exactly the
  # regime where a long local turn starts to EOF. Two bounds keep it sane
  # WITHOUT breaking the tool-call protocol (every tool_call_id still gets its
  # own response message): only the last TOOL_RESULT_WINDOW results carry real
  # payload, older ones collapse to a short stub, and even a "recent" payload
  # is capped at TOOL_RESULT_MAX_BYTES.
  TOOL_RESULT_WINDOW = Integer(ENV.fetch("TOOL_RESULT_WINDOW", 6))
  TOOL_RESULT_MAX_BYTES = Integer(ENV.fetch("TOOL_RESULT_MAX_BYTES", 4000))
  # Per-turn generation budgets (§2). One max_tokens governed every call before:
  # the same 8192 was reserved for the plan, for each intermediate tool-selection
  # turn, and for the final answer. On a single-slot local server that inflates
  # worst-case generation time (and thus the chance a 600s read timeout trips).
  # A plan is a short JSON array; a tool-selection turn is a small tool_calls
  # object plus a one-line narration - neither needs the full cap. The final
  # answer keeps the agent's configured max_tokens (override nil). Env-tunable.
  PLAN_MAX_TOKENS = Integer(ENV.fetch("PLAN_MAX_TOKENS", 1024))
  TOOL_STEP_MAX_TOKENS = Integer(ENV.fetch("TOOL_STEP_MAX_TOKENS", 2048))
  OS_MODES = %w[auto_plan auto_build manual_plan manual_build].freeze
  CHAT_ATTACHMENT_TOOLS = %w[read_asset list_assets].freeze
  HOST_TOOLS = %w[run_command code_executor write_file read_file scaffold file_reader file_writer].freeze
  # Minimum spacing between repeated "thinking" status events (ms). Reasoning
  # models emit many tiny deltas; we forward a status heartbeat, not the text.
  THINKING_THROTTLE_MS = 250
  # Honest tail appended when a streamed reply is cut short by a provider error
  # (§4). Shared verbatim with AgentStreamJob's failure finalize so both error
  # paths write the same sentence - neither buries the partial under a generic
  # apology, and neither double-marks it.
  STOP_MARKER = "\n\n…(reply stopped before finishing)".freeze
  RESEARCH_SOURCES_SECTION = /(?:\A|\n)[ \t]*(?:#+[ \t]*)?Sources[ \t]*:?[ \t]*\n(?:[ \t]*(?:[-*+]|\d+[.])[ \t]+[^\n]*(?:\n|\z)|[ \t]*https?:\/\/[^\n]*(?:\n|\z)|[ \t]*\r?\n)*\z/i
  RESEARCH_MARKDOWN_LINK = %r{(!?)\[([^\]\n]*)\]\((https?://(?:[^\s()]|\([^\s()]*\))+)(?:\s+["'][^"']*["'])?\)}i
  RESEARCH_URL = %r{<(https?://[^<>\s]+)>|(https?://[^\s<>"']+)}i

  # Raised at a cancellation checkpoint when the user pressed Stop. A separate
  # class from the provider errors because nothing failed: the words that
  # arrived are the answer as far as it got, the run exits "cancelled", and the
  # browser is told `stopped` rather than `failed`.
  class Cancelled < StandardError; end

  # A request cannot be interrupted from another process, so #stop flips a flag
  # on the run row and the loop comes back and reads it. An iteration boundary
  # always looks; inside a token stream the reload is throttled so a fast local
  # model does not pay one query per delta.
  CANCEL_POLL_INTERVAL = 0.5

  # §6 build resume: only these durable, overwriting filesystem writes are both
  # checkpointed and skipped when a re-delivered run of the same turn finds them
  # already completed. Re-running a completed workspace write is pure waste;
  # reads and calculations are cheap to redo, and workspace commands may carry
  # side effects we must never silently elide.
  RESUMABLE_WRITE_TOOLS = %w[workspace_write_file].freeze

  attr_reader :agent, :conversation, :user, :source_message

  def initialize(agent:, conversation:, user:, streaming_message: nil, source_message: nil,
                 arrival_at: nil, dispatched_at: nil, request_id: nil)
    @agent = agent
    @conversation = conversation
    @user = user
    @streaming_message = streaming_message
    # The turn's correlation id, handed down by AgentStreamJob. A re-delivered
    # build run replays with the SAME id, which is how §6 lets the retry find an
    # earlier attempt's completed writes and skip them. nil for a runner driven
    # directly (specs, ScheduledTasks::RunJob) - no id, nothing to resume from.
    @request_id = request_id.presence
    # The persisted user Message that triggered this run (when known). Its
    # metadata may carry a per-message tool selection which narrows — never
    # widens — the agent's configured tools.
    @source_message = source_message
    # Process-control-block stamps from BEFORE this run existed: when the user
    # turn landed (arrival) and when a worker actually took the job
    # (dispatch). AgentStreamJob knows both, the Run row does not, and
    # queue wait is only measurable if it is handed over. nil for a runner
    # driven directly (specs, ScheduledTasks::RunJob) — see Run.seed_pcb_metadata.
    @pcb_arrival_at = arrival_at
    @pcb_dispatched_at = dispatched_at
  end

  def run(user_message, stream: true, &block)
    if conversation.mode.present?
      run_with_os(user_message, stream, &block)
    else
      execute_tool_loop(user_message, stream: stream, &block)
    end
  end

  def resume_plan(agent_run, stream: false, &block)
    execute_plan(agent_run, stream, &block)
  end

  def tool_definitions
    names = agent.enabled_tools.map { |t| t.is_a?(Hash) ? t[:name] || t["name"] : t }.compact

    # Registry-level capability gating: a tool backed by a capability whose
    # state is not enabled (e.g. web_search unconfigured) never surfaces to
    # the model — honest definitions, no dead stubs.
    # Phase 4 plugin tools (namespaced "<provider>.<tool>") follow the same
    # honesty rule: they surface only while the catalog knows the tool AND the
    # organization has a connected + active integration for that provider.
    # Unknown dotted names are dropped outright — nothing executes them.
    plugin_names = Tools::Catalog.available_tool_names(agent.organization)
    names = names.select do |name|
      if Tools::Catalog.catalog_tool?(name)
        plugin_names.include?(name)
      elsif name.to_s.include?(".")
        false
      else
        capability_allows_tool?(name)
      end
    end

    # OS modes add sandbox tools even with a chat-only agent configuration.
    # Host filesystem and execution tools are never available in any mode.
    if conversation.mode.in?(OS_MODES)
      os_names = %w[calculator memory_search time]
      workspace_names = %w[workspace_create workspace_write_file workspace_read_file
                           workspace_list_files workspace_execute workspace_install
                           workspace_run_tests workspace_start_preview workspace_get_logs
                           workspace_export workspace_stop]
      names = (names | os_names | workspace_names | attachment_tools | image_tools)
    else
      # Plain chat: conversations carrying user attachments get the read-only
      # asset tools so the agent can actually read uploaded files (uploads,
      # library) instead of claiming it cannot. No attachments -> no extra
      # tools -> the streaming path stays as-is.
      names = (names | attachment_tools | image_tools)
    end
    # Filter last so automatic additions cannot bypass a user's selection.
    per_message_tool_filter(names.reject { |name| HOST_TOOLS.include?(name.to_s) })
  end

  private

  # A tool surfaces only when its backing capability is enabled; tools with
  # no capability mapping (OS tools) always surface.
  def capability_allows_tool?(name)
    capability_key = Agents::ToolRegistry.capability_key_for(name)
    return true if capability_key.nil?
    return Capabilities::Registry.available?(capability_key) unless %w[webfetch web_search deep_research].include?(capability_key)

    organization = ToolIntegration.authorized_organization_for(user, agent_id: agent.id)
    return false unless organization.present?

    return true if capability_key != "webfetch" && Capabilities::Registry.available?(capability_key)

    Capabilities::Registry.available?(capability_key, organization: organization)
  end

  # Per-message tool selection intersects the agent's gated tool list — it can
  # only narrow, never widen. Entries tolerate both shapes the client may have
  # sent (plain names, or {"name" => ...} hashes). An empty/absent selection
  # leaves the agent config untouched.
  def per_message_tool_filter(names)
    meta = source_message&.metadata
    selected = meta.is_a?(Hash) ? Array(meta["tools"]) : []
    return names if selected.empty?

    wanted = selected.map { |t| t.is_a?(Hash) ? (t[:name] || t["name"]) : t }.compact.map(&:to_s)
    names.select { |name| wanted.include?(name.to_s) }
  end

  # Every tool invocation goes through this branch: dotted names belong to the
  # Phase 4 plugin pipeline (Tools::Dispatcher validates arguments, resolves an
  # org-scoped active integration, touches usage); plain names keep using the
  # native registry exactly as before.
  def dispatch_tool_call(tool_name, args)
    unless tool_definitions.include?(tool_name)
      return { error: "Tool is not allowed for this turn: #{tool_name}", error_code: "tool_not_allowed" }
    end

    unless tool_name.to_s.include?(".")
      return Agents::ToolRegistry.execute(tool_name, args, tool_context)
    end

    Tools::Dispatcher.call(
      tool_name,
      arguments: args,
      organization: agent.organization,
      integration_id: integration_id_for(tool_name),
      context: tool_context
    )
  end

  def tool_context
    { user_id: user.id, user: user, agent_id: agent.id, conversation_id: conversation.id,
      cancelled: -> { cancelled?(force: true) }, research_sink: ->(result) { record_research(result) } }
  end

  def record_research(result)
    @research_results ||= []
    @research_results << result.deep_dup
  end

  # The agent config pins a plugin tool to the integration row chosen when it
  # was connected; nil lets the dispatcher resolve the org's active row.
  def integration_id_for(tool_name)
    entry = agent.enabled_tools.find do |t|
      t.is_a?(Hash) && (t[:name] || t["name"]).to_s == tool_name.to_s
    end
    return nil unless entry.is_a?(Hash)

    entry[:integration_id] || entry["integration_id"]
  end

  # Read-only chat tools for attachment-carrying conversations, each further
  # gated by its own capability state (file_extraction, library).
  def attachment_tools
    return [] unless conversation.messages.joins(:message_attachments).exists?

    CHAT_ATTACHMENT_TOOLS.select do |name|
      capability_key = Agents::ToolRegistry.get(name)&.dig(:capability_key)
      capability_key && Capabilities::Registry.available?(capability_key)
    end
  end

  # Phase 3: the generate_image tool rides the same capability gate as the
  # Tools panel — surfaced only while image_generation is enabled (OpenAI key
  # configured). Unconfigured installs never see the schema; the in-flight
  # per-conversation refusal lives in the tool handler itself.
  def image_tools
    Capabilities::Registry.available?("image_generation") ? [ "generate_image" ] : []
  end

  # Re-find records by id: in dev the code reloader can swap model classes
  # mid-process, and a stale instance is then rejected by association
  # assignment ("Agent expected, got Agent"). A fresh find always binds to
  # the current constant and survives reload churn. Test and production
  # environments do not reload constants (no stale-instance problem), and
  # re-finding there would discard test doubles, so this is dev-only.
  def refresh_live_references!
    return unless Rails.env.development?

    @agent = Agent.find(@agent.id) if @agent
    @conversation = Conversation.find(@conversation.id) if @conversation
  end

  def run_with_os(user_message, stream, &block)
    agent_run = AgentRun.create!(
      conversation_id: conversation.id,
      mode: conversation.mode,
      status: "planning"
    )

    broadcast_reasoning_placeholder(agent_run)
    agent_run.append_reasoning("Parse user intent", user_message.truncate(120))
    broadcast_turbo("agent-plan-start", agent_run)

    plan = generate_plan(user_message, agent_run)

    if plan.blank?
      agent_run.update!(status: "completed")
      agent_run.append_reasoning("No plan needed", "Answering directly")
      return execute_tool_loop(user_message, stream: stream, &block)
    end

    agent_run.append_reasoning("Generated plan", "#{plan.size} steps")
    agent_run.todos.create!(plan.each_with_index.map { |t, i| { title: t, status: "pending", position: i } })

    broadcast_turbo("agent-plan", agent_run)

    if agent_run.mode == "manual_plan"
      agent_run.append_reasoning("Waiting for user approval")
      broadcast_turbo("wait-approval", agent_run)
      return { content: "Plan ready — awaiting approval.", plan: agent_run.todos.reload.order(:position).map(&:title), tool_calls: [], tokens: 0 }
    end

    execute_plan(agent_run, stream, &block)
  end

  def broadcast_reasoning_placeholder(agent_run)
    Turbo::StreamsChannel.broadcast_append_to(
      conversation,
      target: "messages-list",
      partial: "agent_runs/reasoning",
      locals: { run: agent_run }
    )
  rescue => e
    Rails.logger.warn "broadcast_reasoning_placeholder error: #{e.message}"
  end

  def generate_plan(user_message, agent_run)
    prompt = <<~PROMPT
      You are Shams Agent OS. Convert the user request into a JSON array of atomic,
      executable, verifiable steps. Do NOT include markdown or backticks — reply with
      only the array.
      Rules:
      - Use only tools enabled for this turn: #{tool_definitions.join(', ')}.
      - File access and execution must use sandbox workspace tools, never the host.
      - For building an app or project: create a sandbox with workspace_create,
        write major files with workspace_write_file, install dependencies with
        workspace_install, then use workspace_run_tests and report real results.
      - If a required sandbox tool is unavailable, report that limitation.
      - 3 to 12 steps, each short and imperative.
      - Pure conversational request (greeting, question, chit-chat) => [].
      Example: ["Create the project directory structure", "Write the main Python module",
        "Write the data models and helpers", "Install dependencies",
        "Run the test suite and report results"]
      Example: []

      User request: #{user_message}
    PROMPT

    raw = chat_for_plan(prompt)
    plan = JSON.parse(raw.to_s[/\[.*\]/m] || raw.to_s)
    plan.is_a?(Array) ? plan.map(&:to_s).reject(&:blank?).first(12) : []
  rescue JSON::ParserError
    []
  end

  def chat_for_plan(prompt)
    resp = build_client_for_agent.chat(messages: [ { role: "user", content: prompt } ], max_tokens: PLAN_MAX_TOKENS)
    resp[:content].to_s
  rescue => e
    Rails.logger.warn "Plan generation failed: #{e.class} #{e.message}"
    ""
  end

  def execute_plan(agent_run, stream, &block)
    refresh_live_references!
    agent_run.update!(status: "executing")

    agent_run.todos.order(:position).each_with_index do |todo, idx|
      break if agent_run.reload.status == "interrupted"
      next if todo.status == "done"

      agent_run.update!(current_step: idx)
      todo.update!(status: "in_progress")
      agent_run.append_reasoning("Executing step #{idx + 1}", todo.title)
      broadcast_turbo("step-start", agent_run, todo)

      result = execute_step(todo.title, stream, &block)

      status = result[:ok] ? "done" : "failed"
      todo.update!(status: status, result: result[:output])
      agent_run.append_reasoning(status == "done" ? "Step completed" : "Step failed", result[:output].to_s.truncate(200))
      broadcast_turbo("step-done", agent_run, todo)

      if agent_run.mode == "manual_build"
        broadcast_turbo("wait-confirm", agent_run, todo)
        break
      end
    end

    if agent_run.reload.status == "interrupted"
      agent_run.append_reasoning("Finalizing", "Run interrupted before completion; output verification skipped")
    else
      # Verify the plan's file targets on disk: done steps whose promised
      # outputs are missing downgrade the run to failed (no false success).
      agent_run.verify_outputs!
    end
    agent_run.append_reasoning("Finalizing", "Creating summary response")
    broadcast_turbo("plan-complete", agent_run)

    todos = agent_run.todos.reload.order(:position)
    done = todos.select { |t| t.status == "done" }
    failed = todos.select { |t| t.status == "failed" }
    return if done.empty? && failed.empty?

    lines = done.each_with_index.flat_map do |todo, idx|
      entry = "#{idx + 1}. #{todo.title}"
      output = todo.result.to_s.strip
      output.present? ? entry + "\n" + output.truncate(400) : entry
    end
    failed.each do |todo|
      lines << "FAILED: #{todo.title} — #{todo.result.to_s.strip.truncate(300)}"
    end

    body = lines.join("\n")
    summary = "Build executed: #{done.size} step(s) completed, #{failed.size} failed.\n\n#{body}"
    summary = summary.truncate(4000)

    if summary.present? && conversation.messages.where(role: "assistant").where("content LIKE ?", "Build executed:%").none?
      conversation.messages.create!(role: "assistant", content: summary)
    end
  end

  def execute_step(step_instruction, stream, &block)
    step_msg = conversation.messages.create!(role: "user", content: "[Step] #{step_instruction}")
    result = execute_tool_loop(step_instruction, stream: stream, &block)
    actions = result[:actions].to_i

    # Evidence gating: a plan step is "done" only when the tool loop actually
    # executed at least one tool action AND neither errored nor hit the
    # iteration limit. Text-only replies (even apologies) used to complete
    # steps — the school-run bug that marked "write models.py" done with no
    # file ever written.
    ok = result[:error].blank? && !result[:incomplete] && actions.positive?
    output = if ok
      result[:content]
    else
      reason = if result[:error].present?
        "Step error: #{result[:error]}"
      elsif result[:cancelled]
        "Step stopped by the user."
      elsif result[:incomplete]
        "Step did not finish within the iteration limit (#{actions} action(s) executed)."
      else
        "No tool action was executed for this step."
      end
      [ reason, result[:content].presence ].compact.join("\n")
    end

    { ok: ok, output: output, actions: actions }
  end

  def broadcast_turbo(action, agent_run, todo = nil)
    html = case action
    when "agent-plan-start", "agent-plan", "plan-complete"
      ApplicationController.render(partial: "agent_runs/plan_card", locals: { run: agent_run })
    when "step-start", "step-done"
      ApplicationController.render(partial: "agent_runs/plan_card", locals: { run: agent_run.reload })
    when "wait-confirm"
      ApplicationController.render(partial: "agent_runs/continue", locals: { run: agent_run.reload })
    when "wait-approval"
      ApplicationController.render(partial: "agent_runs/approval", locals: { run: agent_run })
    end
    return unless html

    Turbo::StreamsChannel.broadcast_replace_to(
      conversation,
      target: "agent-plan-placeholder",
      html: html
    )
  rescue => e
    Rails.logger.warn "broadcast_turbo error: #{e.message}"
  end

  # Every build/OS task gets its own Docker workspace before the model's first
  # turn, so "create me a project" never has to start with a filesystem path.
  # The outcome is recorded as a sentence the system prompt then repeats —
  # including the sentence for failure, because a task that could not get a
  # sandbox must say so instead of pretending to have one.
  def ensure_workspace_for_task!
    @workspace_note = nil
    return unless conversation.mode.in?(OS_MODES)

    health = Workspaces::Provider.available?
    unless health[:manager] && health[:docker]
      @workspace_note = health[:manager] ? "the Docker daemon is not answering" : "the workspace manager is not reachable"
      return
    end

    workspace = Workspaces::Provider.ensure_for(conversation: conversation, user: user)
    @workspace_note = "workspace #{workspace.id} is running (Docker, no network, no host paths)"
  rescue Workspaces::Unavailable, Workspaces::Rejected => e
    @workspace_note = "no workspace could be created: #{e.message}"
  rescue StandardError => e
    Rails.logger.warn "[Workspace] provisioning failed: #{e.class}: #{e.message}"
    @workspace_note = "no workspace could be created (#{e.class})"
  end

  # A build/OS run operates in a sandbox and can span many steps; it gets the
  # larger budget. Plain conversational chat keeps the tight cap.
  def iteration_budget
    conversation.mode.in?(OS_MODES) ? BUILD_MAX_ITERATIONS : MAX_ITERATIONS
  end

  def execute_tool_loop(user_message, stream: true, &block)
    refresh_live_references!
    @research_results = []
    @generating_announced = false
    run_record = Run.create!(
      agent_id: agent.id,
      conversation_id: conversation.id,
      input: { query: user_message },
      status: "running",
      started_at: Time.current,
      metadata: Run.seed_pcb_metadata(
        arrival_at: @pcb_arrival_at,
        dispatched_at: @pcb_dispatched_at,
        started_at: Time.current,
        request_id: @request_id
      ).merge("effective_provider" => effective_provider, "effective_model" => effective_model)
    )
    # Every provider call and every tool invocation below records its own
    # BLOCKED/RUNNING transition on this row. It is an instance variable
    # precisely because those happen in nested methods, which have no other way
    # to know which process they belong to.
    @run_record = run_record
    # §6 build resume: gather the tool actions any EARLIER attempt of this same
    # turn already finished successfully (matched by request_id). #process_tool_calls
    # consults this set to skip re-running completed filesystem writes. Empty
    # when the turn has no id, so a first attempt or a direct runner re-executes
    # everything exactly as before.
    @resume_action_keys = Run.completed_action_keys(
      conversation_id: conversation.id, request_id: @request_id
    )

    conversation.generate_title if conversation.messages.where(role: "user").count == 1

    ensure_workspace_for_task!

    total_tokens = 0
    tool_call_results = []

    begin
      iteration_budget.times do |iteration|
        raise Cancelled if cancelled?(force: true)

        # Which burst this iteration is: the RUNNING transition that follows each
        # blocked interval carries it, so the trace reads iteration 1 -> provider
        # wait -> iteration 2 -> tool wait -> … instead of an anonymous ping-pong.
        @pcb_burst_label = "iteration #{iteration + 1}"
        messages = build_messages(tool_call_results)
        messages.concat(Conversations::TurnAdmission.consume_steering(conversation).map do |content|
          { role: "user", content: content }
        end)
        tool_schemas = tool_schemas_for_selection

        # Generation budget for THIS turn (§2). Only intermediate tool-selection
        # turns are bounded: tools present, not the first turn (which for a plain
        # chat IS the answer), and not the last permitted turn (which is allowed
        # the full cap so a legitimate closing reply is not cut off). Everything
        # else passes nil and keeps the agent's configured max_tokens.
        turn_budget = TOOL_STEP_MAX_TOKENS if tool_schemas.any? && iteration > 0 && iteration < iteration_budget - 1

        response = chat_with_agent_model(messages, tool_schemas, stream: stream, max_tokens: turn_budget, &block)

        total_tokens += response[:tokens] || 0

        if response[:tool_calls].blank?
          # Provider returned no tool calls: this is the assistant's final
          # text answer. When the body is blank we do NOT fake an apology —
          # the message stays empty and carries metadata["empty_response"]
          # so the view can render a distinct "no response" state and the
          # context filter can drop it from history.
          raw = response[:content].to_s
          content, research_meta = finalize_research_answer(raw.strip)
          final_meta = (@streaming_message&.metadata || {}).dup
          final_meta.delete("streaming")
          final_meta["deep_research"] = research_meta unless research_meta.empty?
          final_meta["empty_response"] = true if content.empty?

          # finish_reason "length" means the model hit max_tokens mid-sentence:
          # the reply is cut off, NOT complete. Keep the partial text (do not
          # discard it) but flag it and record the run as incomplete rather than
          # a clean success - the "truncated but succeeded" defect (§2c). It is
          # then honestly resumable instead of silently shipped.
          truncated = response[:finish_reason].to_s == "length"
          final_meta["truncated"] = true if truncated

          if @streaming_message
            @streaming_message.update!(content: content, tokens: response[:tokens] || 0, metadata: final_meta)
            assistant_msg = @streaming_message
          else
            assistant_msg = conversation.messages.create!(
              role: "assistant",
              content: content,
              tokens: response[:tokens] || 0,
              metadata: final_meta
            )
          end

          create_memory(user_message, content) if content.present?

          if truncated
            run_record.finish!(output: content, tokens_used: total_tokens,
              exit_note: "reply truncated at the max_tokens cap (finish_reason=length)")
            return {
              content: content, tool_calls: [], tokens: total_tokens,
              actions: tool_call_results.count { |entry| action_succeeded?(entry[:result]) }, incomplete: true, truncated: true,
              messages: conversation.messages.to_a
            }
          end

          run_record.finish!(output: content, tokens_used: total_tokens)

          return {
            content: content,
            tool_calls: [],
            tokens: total_tokens,
            actions: tool_call_results.count { |entry| action_succeeded?(entry[:result]) },
            messages: conversation.messages.to_a
          }
        end

        tool_call_results = process_tool_calls(response[:tool_calls], tool_call_results)

        if block_given?
          tool_call_results.each do |result|
            yield({ type: "tool_call", tool: result[:tool_name], result: result[:result] })
          end
        end

        break if tool_call_results.length > MAX_TOOL_CALLS_PER_TURN * (iteration + 1)
      end

      fallback_content = "I was unable to complete your request within the allowed iterations."
      if @streaming_message
        streamed = @streaming_message.metadata.merge("error" => "max_iterations")
        streamed.delete("streaming")
        @streaming_message.update!(content: fallback_content, tokens: estimate_tokens(fallback_content), metadata: streamed)
      else
        conversation.messages.create!(role: "assistant", content: fallback_content, tokens: estimate_tokens(fallback_content), metadata: { "error" => "max_iterations" })
      end
      run_record.finish!(output: fallback_content, tokens_used: total_tokens, exit_note: "exited the loop at the iteration cap (#{iteration_budget})")
      { content: fallback_content, tool_calls: [], tokens: total_tokens,
        actions: tool_call_results.count { |entry| action_succeeded?(entry[:result]) }, incomplete: true }

    rescue Cancelled
      # Stopped by the user, not by a failure: keep every word that actually
      # arrived, exit the run cancelled, and hand the caller a verdict it can
      # announce as `stopped` instead of `failed`.
      final_content = persist_cancelled_reply
      run_record.cancel!
      # The same live signal the completed/failed paths emit, so a tab that
      # only listens to status frames retires its indicator immediately.
      yield({ type: "status", phase: "stopped" }) if block_given?
      { content: final_content, tool_calls: [], tokens: total_tokens,
        actions: tool_call_results.count { |entry| action_succeeded?(entry[:result]) }, incomplete: true, cancelled: true }

    rescue => e
      run_record.fail!(e)
      Rails.logger.error "Agent run failed: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n") if e.backtrace
      # Tell the browser to stop the indicator and show a failed state BEFORE
      # the placeholder is replaced — provider errors must never leave a
      # perpetual "thinking" spinner or masquerade as a normal answer.
      # When the provider raised a typed error (see Llm::AnthropicAdapter), carry
      # its machine-readable cause (`error_code`, `retryable`) alongside the human
      # message so the failed status chunk, the persisted message metadata, and the
      # result the job inspects all name the SAME reason. An out-of-credit key then
      # surfaces as provider_credit_insufficient instead of a generic provider_error
      # - and the retryable flag tells the caller whether redelivery can help.
      annotations = error_annotations(e)
      yield({ type: "status", phase: "failed", error: e.message }.merge(annotations)) if block_given?

      # Preserve whatever actually streamed rather than burying it under a fixed
      # apology. A build that got half its files written, or an answer that got
      # half its sentences out, is worth keeping; append an honest marker so the
      # reader knows the reply was cut short BY an error rather than finished.
      # When nothing streamed there is no partial to keep, so we fall back to the
      # plain error sentence. metadata["error"] carries the cause and
      # "stopped_short" flags the truncation for the UI. The streaming job's
      # finalize produces the identical shape (see AgentStreamJob), so the two
      # error paths agree instead of one clobbering the other's partial.
      generic = "I encountered an error while processing your request."
      meta_annotations = annotations.transform_keys(&:to_s)
      if @streaming_message
        partial = @streaming_message.reload.content.to_s
        final_content = partial.strip.empty? ? generic : "#{partial}#{AgentRunner::STOP_MARKER}"
        streamed = @streaming_message.metadata
          .merge("error" => e.message, "stopped_short" => true)
          .merge(meta_annotations)
        streamed.delete("streaming")
        @streaming_message.update!(content: final_content, tokens: estimate_tokens(final_content), metadata: streamed)
      else
        final_content = generic
        conversation.messages.create!(role: "assistant", content: final_content,
          tokens: estimate_tokens(final_content),
          metadata: { "error" => e.message, "stopped_short" => true }.merge(meta_annotations))
      end
      { content: final_content, error: e.message, tool_calls: [], tokens: total_tokens,
        actions: tool_call_results.count { |entry| action_succeeded?(entry[:result]) } }.merge(annotations)
    end
  end

  # The reply as it stood when the run was stopped. The partial is kept
  # verbatim with the same tail the error path appends, so whichever path
  # finalizes the row the reader sees one consistent "stopped here" marker.
  # metadata gets `cancelled`, NOT `error`: the turn was interrupted on
  # request, and nothing about it should read as a provider failure.
  def persist_cancelled_reply
    return "" unless @streaming_message

    partial = @streaming_message.reload.content.to_s
    content = partial.strip.empty? ? partial : "#{partial}#{STOP_MARKER}"
    meta = (@streaming_message.metadata || {}).dup
    meta.delete("streaming")
    meta["cancelled"] = true
    meta["stopped_short"] = true if content.strip.present?
    @streaming_message.update!(content: content, tokens: estimate_tokens(content), metadata: meta)
    content
  end

  def finalize_research_answer(content)
    return [ content, {} ] if @research_results.blank?

    ledger = research_source_ledger
    supported = ledger.map { |source| source[:url] }
    body = content.sub(RESEARCH_SOURCES_SECTION, "").strip
    body, unsupported = sanitize_research_citations(body, supported)
    body = append_research_sources(body, ledger) if body.present? && ledger.any?
    metadata = {
      "runs" => @research_results.map(&:deep_dup),
      "sources" => ledger,
      "citation_validation" => { "supported_urls" => supported, "unsupported_urls" => unsupported.uniq }
    }
    [ body, metadata ]
  end

  def research_source_ledger
    Array(@research_results).flat_map { |result| Array(result[:sources]) }.filter_map do |source|
      next unless source.is_a?(Hash)

      url = Research::DeepResearch.canonical_url(source[:url])
      next unless url

      { source_id: source[:source_id].presence || Research::DeepResearch.source_id(url),
        title: source[:title].to_s.first(300), url: url,
        snippet: source[:snippet].to_s.first(Research::DeepResearch::MAX_SNIPPET), query: source[:query].to_s }
    end.uniq { |source| source[:url] }
  end

  def sanitize_research_citations(content, supported)
    unsupported = []
    linked = content.gsub(RESEARCH_MARKDOWN_LINK) do
      image, label, url = Regexp.last_match.captures
      canonical = Research::DeepResearch.canonical_url(url)
      if canonical && supported.include?(canonical)
        "#{image}[#{label}](#{canonical})"
      else
        unsupported << (canonical || url).to_s.first(2048)
        "#{label.presence || 'source'} (unsupported citation)"
      end
    end
    cleaned = linked.gsub(RESEARCH_URL) do
      token = Regexp.last_match(1) || Regexp.last_match(2)
      core, suffix = split_research_url(token)
      canonical = Research::DeepResearch.canonical_url(core)
      if canonical && supported.include?(canonical)
        "#{canonical}#{suffix}"
      else
        unsupported << (canonical || core).to_s.first(2048)
        "[unsupported citation]#{suffix}"
      end
    end
    [ cleaned, unsupported ]
  end

  def split_research_url(token)
    suffix = +""
    closing = { ")" => "(", "]" => "[", "}" => "{" }
    loop do
      character = token[-1]
      if ".,;:!?".include?(character)
        token = token[0...-1]
        suffix = "#{character}#{suffix}"
      elsif closing.key?(character) && token.count(character) > token.count(closing.fetch(character))
        token = token[0...-1]
        suffix = "#{character}#{suffix}"
      else
        break
      end
    end
    [ token, suffix ]
  end

  def append_research_sources(content, ledger)
    sources = ledger.each_with_index.map do |source, index|
      title = source[:title].to_s.gsub(/\s+/, " ").strip.first(120)
      "#{index + 1}. #{title.presence || source[:url]} — #{source[:url]}"
    end
    [ content.rstrip, "", "Sources:", *sources ].join("\n")
  end

  # Symbol-keyed { error_code:, retryable: } for a typed provider error (see
  # Llm::AnthropicAdapter::LlmError); {} for anything untyped, so OpenAI/local
  # adapters and non-LLM failures keep their existing generic handling.
  def error_annotations(error)
    typed = error.is_a?(Llm::ProviderError) || error.is_a?(Llm::AnthropicAdapter::LlmError)
    return {} unless typed && error.code.present?

    { error_code: error.code.to_s,
      retryable: (error.respond_to?(:retryable?) ? !!error.retryable? : nil) }
  end

  # True once the Stop endpoint has marked THIS run cancelled. Reads through the
  # instance variable rather than a parameter because the checkpoint inside the
  # streaming callback has no other way to reach the run it belongs to.
  def cancelled?(force: false)
    return false unless @run_record

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return false if !force && @next_cancel_check && now < @next_cancel_check

    @next_cancel_check = now + CANCEL_POLL_INTERVAL
    @run_record.reload.cancelled?
  end

  def chat_with_agent_model(messages, tools, stream:, max_tokens: nil, &block)
    client = build_client_for_agent
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stream = false if client.is_a?(Llm::Client) && !client.streaming_supported?

    if stream && block
      @thinking_announced = false
      @last_status_ms = nil
      # Emit a one-shot "connecting" heartbeat before we open the stream so the
      # execution trace can show Connecting → Thinking → Generating → Completed
      # even during the provider handshake latency.
      unless @connecting_announced
        @connecting_announced = true
        yield({ type: "status", phase: "connecting" })
      end
      final_result = with_blocked("provider:#{effective_provider}/#{effective_model}") do
        with_local_model_slot(effective_provider) do
          client.stream_chat(**provider_opts(messages, tools, max_tokens)) do |piece, _full, _tcs, kind|
            # Checked before anything else so a stopped turn never pays for
            # another delta of tokens it will not keep. Raising here unwinds out
            # of the adapter's socket loop; only its TRANSIENT_ERRORS list is
            # rescued there, so Cancelled reaches #execute_tool_loop.
            raise Cancelled if cancelled?

            now_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
            if kind == "reasoning"
              # Never forward the model's private chain-of-thought. Emit a single
              # "thinking" status, then at most one per THINKING_THROTTLE_MS, so the
              # UI shows live progress without leaking reasoning text.
              next if @thinking_announced && @last_status_ms && (now_ms - @last_status_ms) < THINKING_THROTTLE_MS

              @thinking_announced = true
              @last_status_ms = now_ms
              yield({ type: "status", phase: "thinking" })
            elsif piece && !piece.empty?
              yield({ type: "status", phase: "generating" }) unless @generating_announced
              @generating_announced = true
              yield({ type: "content_delta", text: piece })
            end
          end
        end
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      log_provider_metrics(elapsed_ms: elapsed_ms, tokens: final_result[:tokens], stream: true)
      record_inference_result(final_result)
      final_result
    else
      result = with_blocked("provider:#{effective_provider}/#{effective_model}") do
        with_local_model_slot(effective_provider) { client.chat(**provider_opts(messages, tools, max_tokens)) }
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      log_provider_metrics(elapsed_ms: elapsed_ms, tokens: result[:tokens], stream: false)
      record_inference_result(result)
      result
    end
  rescue => e
    code = error_annotations(e)[:error_code]
    record_inference_outcome(error_code: code) if code
    Rails.logger.error "LLM call failed: #{e.class} #{e.message}"
    raise
  end

  def record_inference_result(result)
    error_code = if result[:content].to_s.strip.present? || Array(result[:tool_calls]).any?
                   nil
    else
                   "empty_response"
    end
    record_inference_outcome(error_code: error_code)
  end

  def record_inference_outcome(error_code: nil)
    provider_client = build_client_for_agent
    if provider_client.is_a?(Llm::Client) && (connection = provider_client.connection)
      model = provider_client.inference_model
      if connection.model != model
        connection = Llm::ProviderConnection.new(
          provider: connection.provider, integration: connection.integration, api_key: connection.api_key,
          model: model, base_url: connection.base_url
        )
      end
      Llm::InferenceTracker.record(connection, model, error: error_code, api_family: connection.api_family,
        fingerprint: connection.inference_fingerprint)
      return
    end
    integration = ToolIntegration.connection_for(agent.organization, effective_provider)
    return unless integration

    connection = Llm::ProviderConnection.new(
      provider: effective_provider,
      integration: integration,
      model: effective_model
    )
    Llm::InferenceTracker.record(connection, effective_model, error: error_code,
      fingerprint: connection.inference_fingerprint)
  rescue StandardError => e
    Rails.logger.warn "[LLM] inference-outcome-failed #{e.class}: #{e.message}"
  end

  # Wait on something outside this process, and say so on its control block.
  #
  # The interval is bounded by the call we can actually observe — one provider
  # round-trip, one tool invocation — so it is reported as I/O wait against the
  # named resource rather than as a per-socket-read figure we cannot see from
  # Ruby. The RUNNING transition that follows carries the iteration label, which
  # is what turns a flat list of timestamps into an interleaving trace: the
  # number of these pairs IS the run's context-switch count.
  #
  # `ensure`, because a tool that raises still returns the run to RUNNING (the
  # loop catches it and keeps going) and the trace must not end mid-air.
  def with_blocked(note)
    return yield unless @run_record

    begin
      @run_record.record_state!("blocked", note: note)
      yield
    ensure
      @run_record.record_state!("running", note: @pcb_burst_label)
    end
  end

  # Serialize local-model generations through the process-wide gate; cloud
  # providers run unguarded. The llama.cpp server behind bonsai/ollama has a
  # single slot, so letting several agent jobs hit it at once only queues the
  # extra requests until the adapter's read timeout trips - the mid-stream EOF
  # on long turns. Making them wait for a slot instead is the whole point.
  def with_local_model_slot(provider)
    return yield unless Llm::LocalModelGate.local?(provider)

    Llm::LocalModelGate.instance.acquire { yield }
  end

  # The [LLM] line, plus - for local providers only - a host sample (swap,
  # memory pressure, llama-server RSS) so a slow generation can be diagnosed
  # after the fact as "busy box" vs "slow model". Metrics must never be the
  # reason a run fails, so the whole thing is guarded.
  def log_provider_metrics(elapsed_ms:, tokens:, stream:)
    line = "[LLM] provider=#{effective_provider} model=#{effective_model} " \
           "latency_ms=#{elapsed_ms} tokens=#{tokens} stream=#{stream}"
    sample = Llm::ResourceSampler.sample(provider: effective_provider, model: effective_model)
    if sample.empty?
      Rails.logger.info line
    else
      Rails.logger.info(
        "#{line} swap_used_mb=#{sample[:swap_used_mb]} " \
        "memory_free_pct=#{sample[:memory_free_pct]} llama_rss_mb=#{sample[:llama_rss_mb]}"
      )
    end
  rescue StandardError => e
    Rails.logger.warn "[LLM] metrics-log-failed #{e.class}: #{e.message}"
  end

  def explicit_model_selection
    return @explicit_model_selection if defined?(@explicit_model_selection)

    @explicit_model_selection = source_message&.metadata&.dig("selected_model")&.deep_dup ||
      Llm::ModelSelection.new(user: user, organization: agent.organization, conversation: conversation).snapshot
  end

  def effective_model_selection
    @effective_model_selection ||= explicit_model_selection ||
      { "provider_id" => agent.provider, "model_id" => agent.model }
  end

  def effective_provider
    effective_model_selection&.fetch("provider_id") || agent.provider
  end

  def effective_model
    effective_model_selection&.fetch("model_id") || agent.model
  end

  def build_client_for_agent
    selection = explicit_model_selection
    return agent.llm_client unless selection
    return agent.llm_client if selection["provider_id"] == agent.provider && selection["model_id"] == agent.model

    connection = Llm::ProviderConnection.resolve(
      organization: agent.organization,
      provider: selection["provider_id"],
      model: selection["model_id"]
    )
    Llm::Client.new(provider: selection["provider_id"], model: selection["model_id"], connection: connection,
      temperature: agent.config.fetch("temperature", 0.7), max_tokens: agent.config.fetch("max_tokens", 4096),
      top_p: agent.config.fetch("top_p", nil))
  end

  def tool_schemas_for_selection
    return [] if build_tool_schemas.empty?
    return build_tool_schemas unless explicit_model_selection

    model = Llm::ModelCatalogue.new(agent.organization)
      .resolve!({ "provider_id" => effective_provider, "model_id" => effective_model }, tools: true)
    model[:supports_tools] == true ? build_tool_schemas : []
  end

  # Keyword args for a provider call. max_tokens is only included when a
  # caller asked for a specific per-turn budget; leaving it out makes the client
  # fall back to the agent's configured cap (and keeps the call shape the
  # existing client stubs in the specs expect).
  def provider_opts(messages, tools, max_tokens)
    opts = { messages: messages, tools: tools }
    opts[:max_tokens] = max_tokens if max_tokens
    opts
  end

  def build_messages(tool_call_results)
    messages = []
    messages << { role: "system", content: build_system_prompt }

    conversation.context_messages.each do |msg|
      messages << msg
    end

    messages.concat(build_tool_messages(tool_call_results))
    messages
  end

  # One response message per tool call, always - the protocol requires a tool
  # message for every tool_call_id the model emitted. Only the CONTENT is
  # bounded: the most recent TOOL_RESULT_WINDOW results carry real (capped)
  # payload, anything older collapses to a short stub so a long build does not
  # re-send every file it wrote on every subsequent iteration.
  def build_tool_messages(tool_call_results)
    total = tool_call_results.length
    tool_call_results.each_with_index.map do |result, idx|
      recent = idx >= total - TOOL_RESULT_WINDOW
      {
        role: "tool",
        content: recent ? bound_payload(result[:result]) : stub_payload(result),
        tool_call_id: result[:tool_call_id]
      }
    end
  end

  # Keep the tool protocol's content valid JSON even when the payload is capped.
  def bound_payload(result)
    json = result.to_json
    return json if json.bytesize <= TOOL_RESULT_MAX_BYTES

    original_bytes = json.bytesize
    envelope = { ok: result[:ok], truncated: true, original_bytes: original_bytes,
                 notice: "[truncated #{original_bytes - TOOL_RESULT_MAX_BYTES} bytes]" }
    preview = json.byteslice(0, TOOL_RESULT_MAX_BYTES).scrub
    while preview.present?
      envelope[:preview] = preview
      bounded = envelope.to_json
      return bounded if bounded.bytesize <= TOOL_RESULT_MAX_BYTES

      preview = preview[0, [ preview.length - 32, 0 ].max]
    end
    { truncated: true, original_bytes: original_bytes }.to_json
  end

  # A collapsed older result: enough for the model to recall WHAT happened
  # without re-reading the whole payload.
  def stub_payload(result)
    preview = result[:result].to_s[0, 160]
    "[#{result[:tool_name]} result collapsed to save context: #{preview}…]"
  end

  def build_system_prompt
    base = agent.system_prompt.presence || "You are a helpful assistant."

    # App-internal implementation constraints are only relevant when the agent
    # is operating on the app itself (OS/auto-build modes). Injecting them into
    # every chat hijacks normal conversations into meta-talk about the app's
    # internals instead of answering the user.
    critical = if conversation.mode.present?
      <<~CTX
        Constraints:
        - Auth: session[:user_id]. Action Cable: cookies.signed[:user_id]. No remember_token.
        - Controller creates user Message. Do NOT duplicate. When streaming_message provided, update via update!.
        - Streaming placeholder is created with content: "" and metadata.streaming=true; drop the flag on finalize (never persist ".").
        - Provider: #{agent.provider}, Model: #{agent.model}. Use agent.llm_client for all calls.
        - Tools present -> use non-streaming chat.
        - agent.enabled_tools: strings or hashes. Handle both. Tool IDs top-level.
        - generate_plan returns [] for conversational -> short-circuit to execute_tool_loop.
        - execute_plan skips todos where status == "done".
        - Rails 8.1.3, Solid Queue, PostgreSQL. Run uses finish!(output:, tokens_used:).
        - Streaming updates target [data-streaming-content="<messageId>"].
        - AgentRun status broadcasts Turbo Stream replace of #run-status-<id>.

        Follow strictly. Do not invent routes/helpers. No duplicate messages.
      CTX
    end

    tool_names = tool_definitions
    tools = if tool_names.present?
      "\nAvailable tools: #{tool_names.join(", ")}. Use them when needed and return tool_calls with proper id and name."
    else
      ""
    end

    project_ctx = if conversation.project_id.present?
      proj = conversation.project
      "\nProject context:\n#{proj.instructions_for_system_prompt}"
    else
      ""
    end

    mode_ctx = if conversation.mode.present?
      active_run = conversation.agent_runs.active.last
      status_info = active_run ? " (status: #{active_run.status})" : ""
      <<~CTX

        Current OS mode: #{conversation.mode}#{status_info}

        Sandbox for this task: #{@workspace_note || "not provisioned for this turn"}.

        Execution rules:
        - Build inside the Docker workspace: workspace_write_file,
          workspace_execute, workspace_install, workspace_run_tests,
          workspace_start_preview, workspace_get_logs, workspace_export.
          Paths are relative to /workspace and spaces in them are ordinary —
          there is no reason to rename anything.
        - Host filesystem access and host execution are prohibited, even when
          the sandbox is unavailable. Use only tools in the Available tools list.
          Inspect project files with workspace_read_file / workspace_list_files.
          Pass command arguments as argv tokens; never ask the user to rename
          a folder to work around a tool.
        - For every plan step, call tools first; never claim an action you did
          not run. A workspace is only "ready" when workspace_create said so.
        - A failing command means: read the error, fix it, run again.
        - Emit ONE tool call at a time and wait for its result.
        - Finally, summarize exactly what was created, how to run it, and the
          preview link if the manager produced one. If the sandbox was
          unavailable, say that instead of describing work that did not happen.
      CTX
    else
      ""
    end

    [ base, critical, tools, project_ctx, mode_ctx ].join("\n\n").strip
  end

  def build_tool_schemas
    # Split the gated list: native registry schemas plus Phase 4 catalog
    # schemas for namespaced plugin tools (the registry drops those).
    # Array#partition hands back [matching, non-matching].
    catalog_names, registry_names = tool_definitions.partition { |name| Tools::Catalog.catalog_tool?(name) }
    Agents::ToolRegistry.schemas(registry_names) + Tools::Catalog.schemas(catalog_names)
  end

  def process_tool_calls(tool_calls, previous_results)
    results = []

    tool_calls.each do |tool_call|
      fn = tool_call[:function] || tool_call["function"] || {}
      tool_name = fn["name"] || fn[:name]
      arguments = fn["arguments"] || fn[:arguments]

      begin
        args = if arguments.is_a?(String)
          JSON.parse(arguments)
        elsif arguments.is_a?(Hash)
          arguments
        else
          {}
        end
        tool_call_id = tool_call["id"] || tool_call[:id] || SecureRandom.hex(16)

        # §6 build resume: a re-delivered run of the same turn (matched by
        # request_id) must not re-write files an earlier attempt already wrote.
        # Recognise the completed write, hand the model a synthetic success for
        # its tool_call_id (the protocol still needs a response per call), and
        # skip the dispatch. Everything outside the resumable-write allowlist -
        # or whose earlier attempt did not cleanly succeed - runs normally.
        if resumable_action?(tool_name, args)
          Rails.logger.info("[ToolCall] tool=#{tool_name} conv=#{conversation.id} resumed=true")
          results << {
            tool_call_id: tool_call_id,
            tool_name: tool_name,
            arguments: args,
            result: { ok: true, resumed: true, note: "already completed in an earlier attempt" }
          }
          next
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # A tool call is the process waiting on something outside itself, so it
        # is charged as I/O against the named resource — exactly what a real
        # process does when it blocks on a device.
        result = with_blocked("tool:#{tool_name}") { dispatch_tool_call(tool_name, args) }
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        Rails.logger.info(
          "[ToolCall] tool=#{tool_name} conv=#{conversation.id} user=#{user.id} latency_ms=#{elapsed_ms} error=#{false}"
        )

        # Persist the outcome so a retry of this turn can skip it (§6). Guarded
        # inside the model, so a checkpoint that cannot be written never fails
        # the run.
        record_tool_checkpoint(tool_name, args, result)

        results << {
          tool_call_id: tool_call_id,
          tool_name: tool_name,
          arguments: args,
          result: result
        }
      rescue JSON::ParserError
        Rails.logger.warn "[ToolCall] tool=#{tool_name} conv=#{conversation.id} error=invalid_json"
        results << {
          tool_call_id: tool_call["id"] || tool_call[:id] || SecureRandom.hex(16),
          tool_name: tool_name,
          arguments: { _raw: arguments.to_s },
          result: { error: "Invalid JSON in tool arguments: #{arguments.to_s[0..100]}" }
        }
      rescue => e
        Rails.logger.error "[ToolCall] tool=#{tool_name} conv=#{conversation.id} error=#{e.class} latency_ms=#{elapsed_ms rescue 0}"
        results << {
          tool_call_id: tool_call["id"] || tool_call[:id] || SecureRandom.hex(16),
          tool_name: tool_name,
          arguments: arguments,
          result: { error: e.message }
        }
      end
    end

    results
  end

  # ── §6 build resume helpers ────────────────────────────────────────
  #
  # Is this action one a re-delivered run of the same turn should skip? Only a
  # durable write on the allowlist whose exact call already succeeded in an
  # earlier attempt of the same request_id. Every other call - a read, a
  # calculation, an arbitrary command, or a write that previously errored -
  # runs again, because eliding THOSE could drop side effects the user expects.
  def resumable_action?(tool_name, args)
    return false if @resume_action_keys.nil? || @resume_action_keys.empty?
    return false unless RESUMABLE_WRITE_TOOLS.include?(tool_name.to_s)
    return false unless tool_definitions.include?(tool_name)

    @resume_action_keys.include?(action_key(tool_name, args))
  end

  # Write this action's outcome to the run's checkpoint so the NEXT attempt can
  # consult it. The model itself is guarded, so a checkpoint that cannot be
  # persisted is logged and swallowed - instrumentation must never fail a run.
  def record_tool_checkpoint(tool_name, args, result)
    return unless @run_record

    @run_record.record_tool_action!(
      tool_name,
      key: action_key(tool_name, args),
      ok: action_succeeded?(result),
      note: checkpoint_note(tool_name, result)
    )
  rescue StandardError => e
    Rails.logger.warn "[ToolCall] checkpoint-skipped tool=#{tool_name} #{e.class}: #{e.message}"
  end

  # A stable signature for one call: the tool name plus its arguments, with keys
  # stringified and sorted so the same logical call always hashes the same - even
  # if a retry's JSON differs in key order or symbol-vs-string form.
  def action_key(tool_name, args)
    Digest::SHA256.hexdigest("#{tool_name}\u0000#{canonical_json(args)}")
  end

  def canonical_json(value)
    case value
    when Hash
      value.map { |k, v| [ k.to_s, v ] }.sort_by { |k, _v| k }
        .then { |pairs| "{" + pairs.map { |k, v| "#{k.to_json}:#{canonical_json(v)}" }.join(",") + "}" }
    when Array
      "[" + value.map { |v| canonical_json(v) }.join(",") + "]"
    else
      value.to_json
    end
  end

  # Did the tool actually succeed? A hash carrying an error is not a success, and
  # an explicit ok:false is not a success - so such an action is re-run, not
  # skipped, and re-attempted rather than treated as done.
  def action_succeeded?(result)
    return false unless result.is_a?(Hash)
    return false if result[:error].present? || result["error"].present?

    ok = result.key?(:ok) ? result[:ok] : result["ok"]
    ok != false
  end

  # A compact, human-readable trace line (path + byte count for a write) stored
  # with the checkpoint; never relied on for matching, only for diagnosis.
  def checkpoint_note(tool_name, result)
    return tool_name.to_s unless result.is_a?(Hash)

    path = result[:path] || result["path"]
    bytes = result[:bytes_written] || result["bytes_written"]
    [ path.presence, (bytes ? "#{bytes}B" : nil) ].compact.join(" ").presence || tool_name.to_s
  end

  def create_memory(user_message, assistant_response)
    memory = Memory.create!(
      user: user,
      agent: agent,
      content: "User: #{user_message}\nAssistant: #{assistant_response}".truncate(2000),
      source_type: "conversation",
      source_id: conversation.id,
      metadata: { conversation_id: conversation.id, tokens: estimate_tokens(user_message) + estimate_tokens(assistant_response) }
    )

    EmbeddingJob.perform_later(memory.id)
  end

  def estimate_tokens(text)
    (text.to_s.length / 4.0).ceil
  end
end
