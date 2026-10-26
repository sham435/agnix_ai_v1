class AgentRunner
  MAX_ITERATIONS = 10
  MAX_TOOL_CALLS_PER_TURN = 5
  OS_MODES = %w[auto_plan auto_build manual_plan manual_build].freeze
  CHAT_ATTACHMENT_TOOLS = %w[read_asset list_assets].freeze
  # Minimum spacing between repeated "thinking" status events (ms). Reasoning
  # models emit many tiny deltas; we forward a status heartbeat, not the text.
  THINKING_THROTTLE_MS = 250

  attr_reader :agent, :conversation, :user

  def initialize(agent:, conversation:, user:, streaming_message: nil)
    @agent = agent
    @conversation = conversation
    @user = user
    @streaming_message = streaming_message
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
    names = names.select { |name| capability_allows_tool?(name) }

    # OS modes always execute on this machine: guarantee the execution tools
    # are available even when the agent's configured tool list is chat-only.
    if conversation.mode.in?(OS_MODES)
      os_names = %w[run_command code_executor write_file read_file calculator memory_search time]
      names = (names | os_names | attachment_tools | image_tools)
    else
      # Plain chat: conversations carrying user attachments get the read-only
      # asset tools so the agent can actually read uploaded files (uploads,
      # library) instead of claiming it cannot. No attachments -> no extra
      # tools -> the streaming path stays as-is.
      names = (names | attachment_tools | image_tools)
    end
    names
  end

  private

  # A tool surfaces only when its backing capability is enabled; tools with
  # no capability mapping (OS tools) always surface.
  def capability_allows_tool?(name)
    capability_key = Agents::ToolRegistry.capability_key_for(name)
    capability_key.nil? || Capabilities::Registry.available?(capability_key)
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
      - Steps must be doable with the tools: run_command (bash), write_file,
        read_file, code_executor (python/ruby), memory_search.
      - For building an app or project: one step to create the directory structure,
        one step per major file (write_file), then install any dependencies, then a
        final step that runs the build/tests and reports results.
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
    resp = agent.llm_client.chat(messages: [ { role: "user", content: prompt } ])
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

  def execute_tool_loop(user_message, stream: true, &block)
    refresh_live_references!
    @generating_announced = false
    run_record = Run.create!(
      agent_id: agent.id,
      conversation_id: conversation.id,
      input: { query: user_message },
      status: "running",
      started_at: Time.current
    )

    conversation.generate_title if conversation.messages.where(role: "user").count == 1

    total_tokens = 0
    tool_call_results = []

    begin
      MAX_ITERATIONS.times do |iteration|
        messages = build_messages(tool_call_results)
        tool_schemas = build_tool_schemas

        response = chat_with_agent_model(messages, tool_schemas, stream: stream, &block)

        total_tokens += response[:tokens] || 0

        if response[:tool_calls].blank?
          # Provider returned no tool calls: this is the assistant's final
          # text answer. When the body is blank we do NOT fake an apology —
          # the message stays empty and carries metadata["empty_response"]
          # so the view can render a distinct "no response" state and the
          # context filter can drop it from history.
          raw = response[:content].to_s
          content = raw.strip
          final_meta = (@streaming_message&.metadata || {}).dup
          final_meta.delete("streaming")
          final_meta["empty_response"] = true if content.empty?

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

          run_record.finish!(output: content, tokens_used: total_tokens)

          return {
            content: content,
            tool_calls: [],
            tokens: total_tokens,
            actions: tool_call_results.length,
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
      run_record.finish!(output: fallback_content, tokens_used: total_tokens)
      { content: fallback_content, tool_calls: [], tokens: total_tokens,
        actions: tool_call_results.length, incomplete: true }

    rescue => e
      run_record.fail!(e)
      Rails.logger.error "Agent run failed: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n") if e.backtrace
      # Tell the browser to stop the indicator and show a failed state BEFORE
      # the placeholder is replaced — provider errors must never leave a
      # perpetual "thinking" spinner or masquerade as a normal answer.
      yield({ type: "status", phase: "failed", error: e.message }) if block_given?
      error_msg = "I encountered an error while processing your request."
      if @streaming_message
        streamed = @streaming_message.metadata.merge("error" => e.message)
        streamed.delete("streaming")
        @streaming_message.update!(content: error_msg, tokens: estimate_tokens(error_msg), metadata: streamed)
      else
        conversation.messages.create!(role: "assistant", content: error_msg, tokens: estimate_tokens(error_msg), metadata: { "error" => e.message })
      end
      { content: error_msg, error: e.message, tool_calls: [], tokens: total_tokens,
        actions: tool_call_results.length }
    end
  end

  def chat_with_agent_model(messages, tools, stream:, &block)
    client = build_client_for_agent
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
      final_result = client.stream_chat(messages: messages, tools: tools) do |piece, _full, _tcs, kind|
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
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info "[LLM] provider=#{agent.provider} model=#{agent.model} latency_ms=#{elapsed_ms} tokens=#{final_result[:tokens]} stream=true"
      final_result
    else
      result = client.chat(messages: messages, tools: tools)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info "[LLM] provider=#{agent.provider} model=#{agent.model} latency_ms=#{elapsed_ms} tokens=#{result[:tokens]} stream=false"
      result
    end
  rescue => e
    Rails.logger.error "LLM call failed: #{e.class} #{e.message}"
    raise
  end

  def build_client_for_agent
    agent.llm_client
  end

  def build_messages(tool_call_results)
    messages = []
    messages << { role: "system", content: build_system_prompt }

    conversation.context_messages.each do |msg|
      messages << msg
    end

    tool_call_results.each do |result|
      messages << {
        role: "tool",
        content: result[:result].to_json,
        tool_call_id: result[:tool_call_id]
      }
    end

    messages
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

    tools = if agent.enabled_tools.present?
      tool_names = agent.enabled_tools.map { |t| t.is_a?(Hash) ? t[:name] || t["name"] : t }.compact
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

        Execution rules:
        - You act ON THIS MACHINE through real tools: run_command (bash),
          write_file, read_file, code_executor (python/ruby).
        - For every plan step, call tools first; never claim an action you did
          not run. Verify results (ls, cat, run tests) before saying done.
        - A failing command means: read the error, fix it, run again.
        - Emit ONE tool call at a time and wait for its result.
        - Finally, summarize exactly what was created and how to run it.
      CTX
    else
      ""
    end

    [ base, critical, tools, project_ctx, mode_ctx ].join("\n\n").strip
  end

  def build_tool_schemas
    Agents::ToolRegistry.schemas(tool_definitions)
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

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Agents::ToolRegistry.execute(tool_name, args, {
          user_id: user.id,
          user: user,
          agent_id: agent.id,
          conversation_id: conversation.id
        })
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        Rails.logger.info(
          "[ToolCall] tool=#{tool_name} conv=#{conversation.id} user=#{user.id} latency_ms=#{elapsed_ms} error=#{false}"
        )

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
