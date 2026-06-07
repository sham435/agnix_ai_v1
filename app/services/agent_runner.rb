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

  def initialize(agent:, conversation:, user:)
    @agent = agent
    @conversation = conversation
    @user = user
  end

  def run(user_message, stream: true, &block)
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
          if response[:content].blank?
            assistant_msg = conversation.messages.create!(
              role: "assistant",
              content: "I'm sorry, I couldn't generate a response.",
              tokens: 0
            )
            run_record.finish!(output: "I'm sorry, I couldn't generate a response.", tokens_used: total_tokens)
            return { content: "I'm sorry, I couldn't generate a response.", tool_calls: [], tokens: total_tokens, messages: conversation.messages.to_a }
          end

          assistant_msg = conversation.messages.create!(
            role: "assistant",
            content: response[:content],
            tokens: response[:tokens]
          )

          create_memory(user_message, response[:content])

          run_record.finish!(output: response[:content], tokens_used: total_tokens)

          return {
            content: response[:content],
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
      assistant_msg = conversation.messages.create!(
        role: "assistant",
        content: fallback_content,
        tokens: estimate_tokens(fallback_content)
      )
      run_record.finish!(output: fallback_content, tokens_used: total_tokens)
      { content: fallback_content, tool_calls: [], tokens: total_tokens }

    rescue => e
      run_record.fail!(e)
      Rails.logger.error "Agent run failed: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      error_msg = "I encountered an error while processing your request."
      conversation.messages.create!(role: "assistant", content: error_msg, tokens: estimate_tokens(error_msg))
      { content: error_msg, error: e.message, tool_calls: [], tokens: total_tokens }
    end
  end

  def tool_definitions
    agent.enabled_tools.map { |t| t.is_a?(Hash) ? t[:name] || t["name"] : t }.compact
  end

  private

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
    system_prompt = build_system_prompt

    if conversation.project
      project_instructions = conversation.project.instructions_for_system_prompt
      system_prompt += "\n\n#{project_instructions}" if project_instructions.present?
    end

    messages << { role: "system", content: system_prompt }

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
    prompt = agent.system_prompt.to_s

    prompt += "\n\nCurrent time: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"

    enabled_tools = agent.enabled_tools
    if enabled_tools.any?
      prompt += "\n\nYou have access to the following tools: #{enabled_tools.map { |t| t.is_a?(Hash) ? t[:name] || t : t }.join(', ')}"
    end

    prompt
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
        tool_call_id = tool_call["id"] || tool_call[:id]

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
