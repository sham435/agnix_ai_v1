# frozen_string_literal: true

module Llm
  # Stateless OpenAI-compatible chat-completions gateway.
  #
  # OpenCode (and any other OpenAI-protocol client) reaches the local model stack
  # through here instead of the session-scoped /conversations flow. The gateway
  # holds no conversation state of its own: every call is one self-contained
  # completion over the configured provider - today the local Bonsai llama.cpp
  # server - and renders the answer in the OpenAI wire format (chat.completion,
  # plus SSE chat.completion.chunk when stream: true).
  #
  # It reuses Llm::Client's provider dispatch (provider -> adapter) rather than
  # duplicating provider logic, so the Bonsai-specific settings (llama.cpp base
  # URL, model id, enable_thinking off, sampling) stay in one place.
  #
  # Request/response mapping kept honest and minimal:
  #   - incoming OpenAI messages (string keys, OpenAI roles incl. "tool" and
  #     assistant "tool_calls") are converted to the Llm adapter's internal shape
  #     before the provider call and the answer is converted back on the way out;
  #   - incoming OpenAI tool definitions ({type: "function", function: {...}}) are
  #     converted to the internal {name:, description:, parameters:} shape;
  #   - reasoning_content deltas are forwarded as streamed reasoning.
  class OpenaiGateway
    attr_reader :provider, :model, :api_key, :temperature, :max_tokens, :top_p

    def initialize(provider: "bonsai", model: nil, api_key: nil, temperature: 0.7, max_tokens: nil, top_p: nil)
      @provider = provider
      @model = model
      @api_key = api_key
      @temperature = temperature
      @max_tokens = max_tokens
      @top_p = top_p
    end

    # Non-streaming completion. Returns an OpenAI chat.completion response hash.
    def complete(messages:, tools: [], max_tokens: nil, temperature: nil, top_p: nil)
      result = build_client(max_tokens, temperature, top_p).chat(
        messages: to_internal_messages(messages),
        tools: to_internal_tools(tools),
        stream: false,
        max_tokens: max_tokens
      )

      message = { role: "assistant", content: result[:content].to_s }
      message[:tool_calls] = result[:tool_calls] if result[:tool_calls].present?

      {
        id: "chatcmpl-#{SecureRandom.uuid}",
        object: "chat.completion",
        created: Time.now.to_i,
        model: @model,
        choices: [ { index: 0, message: message, finish_reason: result[:finish_reason] } ],
        usage: {
          prompt_tokens: estimate_tokens(messages),
          completion_tokens: result[:tokens].to_i,
          total_tokens: estimate_tokens(messages) + result[:tokens].to_i
        }
      }
    end

    # Streaming completion. Returns `{ chunks:, finish_reason:, tool_calls: }` where
    # `chunks` holds the OpenAI chat.completion.chunk payloads in arrival order (each
    # with a nil finish_reason) and the terminal chunk is described by the result.
    def stream(messages:, tools: [], max_tokens: nil, temperature: nil, top_p: nil)
      client = build_client(max_tokens, temperature, top_p)
      chunks = []
      final = client.stream_chat(messages: messages, tools: tools, max_tokens: max_tokens) do |piece, _full, _tool_calls, kind|
        next if piece.nil? || piece.to_s.empty?

        delta = if kind.to_s == "reasoning"
                  { "reasoning_content" => piece.to_s }
        else
                  { "content" => piece.to_s }
        end
        chunks << { delta: chunks.empty? ? delta.merge("role" => "assistant") : delta, finish_reason: nil }
      end

      finish_reason = final[:finish_reason].to_s
      tool_calls = final[:tool_calls] || []
      terminal_delta = tool_calls.empty? ? {} : { "tool_calls" => tool_calls.each_with_index.map { |tc, i| { index: i, id: tc[:id], type: "function", function: tc[:function] } } }

      {
        chunks: chunks,
        finish_reason: finish_reason,
        tool_calls: tool_calls,
        terminal_delta: terminal_delta,
        model: @model,
        created: Time.now.to_i
      }
    end

    private

    def build_client(max_tokens, temperature, top_p)
      Llm::Client.new(
        provider: @provider,
        model: @model,
        api_key: @api_key,
        temperature: temperature || @temperature,
        max_tokens: max_tokens || @max_tokens,
        top_p: top_p || @top_p
      )
    end

    # OpenAI wire messages -> Llm adapter internal messages (symbol keys, adapter
    # shape). Roles: "system" | "user" | "assistant" | "tool". Assistant tool-call
    # turns carry tool_calls; tool results carry tool_call_id.
    def to_internal_messages(openai_messages)
      Array(openai_messages).map do |m|
        role = value(m, "role").to_s
        internal = { role: role, content: value(m, "content").to_s }
        if role == "tool"
          internal[:tool_call_id] = value(m, "tool_call_id")
        elsif role == "assistant" && value(m, "tool_calls")
          internal[:tool_calls] = value(m, "tool_calls")
        end
        internal
      end
    end

    # OpenAI tool definitions -> Llm adapter internal tool shape.
    def to_internal_tools(openai_tools)
      Array(openai_tools).filter_map do |t|
        fn = t["function"] || t[:function] || t || {}
        name = value(fn, "name").to_s
        next nil if name.empty?

        {
          name: name,
          description: value(fn, "description").to_s,
          parameters: value(fn, "parameters") || { type: "object", properties: {}, required: [] }
        }
      end
    end

    def value(hash, key)
      return nil if hash.nil?

      hash[key] || hash[key.to_sym]
    end

    def estimate_tokens(messages)
      Array(messages).sum do |m|
        value(m, "content").to_s.length / 4.0
      end.ceil
    end
  end
end
