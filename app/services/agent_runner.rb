class AgentRunner
  MAX_ITERATIONS = 10
  MAX_TOOL_CALLS_PER_TURN = 5

  FALLBACK_MODELS = %w[
    deepseek-v4-flash-free
    big-pickle
    nemotron-3-super-free
    minimax-m3-free
    mimo-v2.5-free
  ].freeze

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
    agent.enabled_tools.map { |t| t.is_a?(Hash) ? t[:name] || t["name"] : t }.compact
  end

  private

  # ── OS Plan / Execute flow ──────────────────────────────────────────

  def run_with_os(user_message, stream, &block)
    agent_run = AgentRun.create!(
      conversation: conversation,
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
      You are Agnix Agent OS. Given the user request, return ONLY a JSON array of strings.
      Each string is one atomic, verifiable step. Keep steps small.
      If the request is purely conversational (greeting, question, chit-chat), return an empty array [].
      Do NOT include markdown, backticks, or explanation — just the array.

      Example: ["Search knowledge base for Rails deployment", "Write deployment checklist file"]
      Example: []

      User request: #{user_message}
    PROMPT

    raw = chat_for_plan(prompt)
    JSON.parse(raw)
  rescue JSON::ParserError
    []
  end

  def chat_for_plan(prompt)
    client = Llm::Client.new(
      provider: "opencode",
      model: FALLBACK_MODELS.first,
      api_key: api_key,
      temperature: 0.3,
      max_tokens: 1024
    )
    resp = client.chat(messages: [{ role: "user", content: prompt }])
    resp[:content].to_s
  end

  def execute_plan(agent_run, stream, &block)
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

    agent_run.update!(status: "completed")
    agent_run.append_reasoning("Finalizing", "Creating summary response")
    broadcast_turbo("plan-complete", agent_run)

    step_outputs = agent_run.todos.order(:position).map { |t| t.result.to_s.strip }.reject(&:blank?)
    if step_outputs.any? && conversation.messages.where(role: "assistant").where("content LIKE ?", "[Step summary]%").none?
      summary = step_outputs.first.truncate(2000)
      conversation.messages.create!(role: "assistant", content: summary, agent: agent)
    end
  end

  def execute_step(step_instruction, stream, &block)
    step_msg = conversation.messages.create!(role: "user", content: "[Step] #{step_instruction}")
    result = execute_tool_loop(step_instruction, stream: stream, &block)
    { ok: result[:error].blank?, output: result[:content] || result[:error] }
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

  # ── Existing tool-call loop (unchanged logic) ───────────────────────

  def execute_tool_loop(user_message, stream: true, &block)
    run_record = Run.create!(
      agent: agent,
      conversation: conversation,
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

        response = chat_with_fallback(messages, tool_schemas, stream: stream, &block)

        total_tokens += response[:tokens] || 0

        if response[:tool_calls].blank?
          content = response[:content].presence || "I'm sorry, I couldn't generate a response."

          if @streaming_message
            @streaming_message.update!(content: content, tokens: response[:tokens] || 0)
            assistant_msg = @streaming_message
          else
            assistant_msg = conversation.messages.create!(
              role: "assistant",
              content: content,
              tokens: response[:tokens] || 0
            )
          end

          create_memory(user_message, content)

          run_record.finish!(output: content, tokens_used: total_tokens)

          return {
            content: content,
            tool_calls: [],
            tokens: total_tokens,
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
        @streaming_message.update!(content: fallback_content, tokens: estimate_tokens(fallback_content))
      else
        conversation.messages.create!(role: "assistant", content: fallback_content, tokens: estimate_tokens(fallback_content))
      end
      run_record.finish!(output: fallback_content, tokens_used: total_tokens)
      { content: fallback_content, tool_calls: [], tokens: total_tokens }

    rescue => e
      run_record.fail!(e)
      Rails.logger.error "Agent run failed: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      error_msg = "I encountered an error while processing your request."
      if @streaming_message
        @streaming_message.update!(content: error_msg, tokens: estimate_tokens(error_msg))
      else
        conversation.messages.create!(role: "assistant", content: error_msg, tokens: estimate_tokens(error_msg))
      end
      { content: error_msg, error: e.message, tool_calls: [], tokens: total_tokens }
    end
  end

  def chat_with_fallback(messages, tools, stream:, &block)
    last_error = nil

    FALLBACK_MODELS.each do |model|
      begin
        client = Llm::Client.new(
          provider: "opencode",
          model: model,
          api_key: api_key,
          temperature: agent.config.fetch("temperature", 0.7).to_f,
          max_tokens: agent.config.fetch("max_tokens", 4096).to_i
        )

        if stream && block && tools.empty?
          final_result = client.stream_chat(messages: messages, tools: tools) do |chunk, full_content, current_tools|
            yield({ type: "chunk", content: chunk, full: full_content }) if block
          end
          return final_result
        else
          return client.chat(messages: messages, tools: tools)
        end
      rescue => e
        Rails.logger.warn "Model #{model} failed: #{e.class} #{e.message[0..200]}"
        last_error = e
        next
      end
    end

    raise last_error || StandardError.new("All models failed")
  end

  def api_key
    ENV.fetch("OPENCODE_API_KEY", "sk-yMSXAwAnIsdYNfmXWmODBCCqvsigqlcjTNEYLH4VP6XxgU74N2NOLMxYH8HHKcqr")
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

    critical = <<~CTX
      Critical Context for this app:

      1. Authentication
         - Auth is via session[:user_id] (server-side, wiped on restart). Action Cable uses cookies.signed[:user_id].
         - Do NOT reference remember_token — it is no longer used for auth.

      2. Message creation
         - The controller already creates the user Message. Do NOT create duplicate user messages.
         - When streaming_message is provided, update it in place via update! instead of creating a new Message.
         - Create streaming Message early with content: "." to pass validations, then stream chunks by message_id.

      3. OpenCode proxy
         - ENV["OPENCODE_API_KEY"] is NOT set. Use the hardcoded fallback key in AgentRunner#api_key.
         - Base URL is opencode.ai/zen OpenAI-compatible proxy.
         - Fallback models in order: deepseek-v4-flash-free, big-pickle, nemotron-3-super-free, minimax-m3-free, mimo-v2.5-free.
         - When tools are present, use non-streaming chat. Streaming drops tool call metadata in deltas.

      4. Tools
         - agent.enabled_tools can be strings or hashes with name/enabled keys. Handle both.
         - Tool call IDs must be top-level, not nested in metadata.

      5. Agent OS loop
         - generate_plan returns [] for conversational prompts. In that case run_with_os must short-circuit to execute_tool_loop.
         - execute_plan must skip todos where status == "done" to support resume.
         - After plan execution, if step outputs exist and no assistant message was created, create a final safety net message.

      6. Rails specifics
         - Rails 8.1.3, Solid Queue, PostgreSQL, Stimulus 3.2, Turbo 8.0, Importmap.
         - config.active_job.queue_adapter = :inline in dev and test.
         - Run model uses finish!(output:, tokens_used:) not complete!.
         - pgvector type is registered in config/initializers/pgvector.rb. Embeddings serialize as "[0.1,0.2]".
         - Turbo.StreamActions.redirect is registered in app/javascript/application.js.

      7. UI contracts
         - Streaming updates target [data-streaming-content="<messageId>"].
         - AgentRun status changes broadcast Turbo Stream replace of #run-status-<id> via after_update_commit.
         - Reasoning steps are stored in reasoning_steps JSONB and broadcast to #reasoning-<id>.

      Follow these constraints strictly. Do not invent routes or helpers. Do not create duplicate messages.
    CTX

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
      "\nCurrent OS mode: #{conversation.mode}#{status_info}"
    else
      ""
    end

    [base, critical, tools, project_ctx, mode_ctx].join("\n\n").strip
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

        result = Agents::ToolRegistry.execute(tool_name, args, {
          user_id: user.id,
          agent_id: agent.id,
          conversation_id: conversation.id
        })

        results << {
          tool_call_id: tool_call_id,
          tool_name: tool_name,
          arguments: args,
          result: result
        }
      rescue JSON::ParserError
        results << {
          tool_call_id: tool_call["id"] || tool_call[:id],
          tool_name: tool_name,
          arguments: { _raw: arguments.to_s },
          result: { error: "Invalid JSON in tool arguments: #{arguments.to_s[0..100]}" }
        }
      rescue => e
        results << {
          tool_call_id: tool_call["id"] || tool_call[:id],
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
