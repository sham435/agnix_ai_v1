# Anthropic Claude API adapter.
# API docs: https://docs.anthropic.com/en/api/messages
module Llm
  class AnthropicAdapter
    BASE_URL = "https://api.anthropic.com/v1"

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120

    attr_reader :api_key, :model

    def initialize(api_key:, model:)
      @api_key = api_key
      @model = model
    end

    def chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, stream: false)
      if stream
        stream_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      else
        sync_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      end
    end

    def stream_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, &block)
      body = build_request_body(messages, tools, temperature, max_tokens, top_p)
      body[:stream] = true

      full_content = +""
      tool_calls = []
      raw = +""
      saw_sse = false

      HTTParty.post("#{BASE_URL}/messages",
        headers: headers,
        body: body.to_json,
        stream_body: true,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
      ) do |chunk|
        raw << chunk.to_s
        chunk.to_s.each_line do |line|
          line = line.chomp
          next unless line.start_with?("data: ")
          saw_sse = true
          data = line.delete_prefix("data: ")
          next if data == "[DONE]"

          begin
            event = JSON.parse(data)
            case event["type"]
            when "content_block_start"
              block_data = event["content_block"]
              if block_data["type"] == "tool_use"
                tool_calls << {
                  id: block_data["id"],
                  type: "function",
                  function: {
                    name: block_data["name"],
                    arguments: block_data["input"].to_json
                  }
                }
              end
            when "content_block_delta"
              delta = event["delta"]
              if delta["type"] == "text_delta"
                text = delta["text"]
                full_content << text
                yield(text, full_content, tool_calls) if block_given?
              elsif delta["type"] == "input_json_delta"
                # Tool call arguments accumulating.
                if tool_calls.any?
                  last_tool = tool_calls.last
                  args = JSON.parse(last_tool[:function][:arguments] + delta["partial_json"]) rescue nil
                  last_tool[:function][:arguments] = (last_tool[:function][:arguments] + delta["partial_json"]) if args.nil?
                end
              end
            when "content_block_stop"
              # Tool call finished.
            when "message_delta"
              # Final metadata.
            end
          rescue JSON::ParserError
            next
          end
        end
      end

      # Buffered-response fallback. We ask for a stream, but some gateways and
      # models ignore stream:true and return one complete JSON message. Without
      # this the SSE parser yields nothing and the turn looks "empty". Parse the
      # raw body as a non-streaming message and surface its text as a single
      # content delta so streaming consumers still receive genuine tokens.
      if !saw_sse && full_content.empty? && tool_calls.empty? && !raw.empty?
        parsed = (JSON.parse(raw) rescue nil)

        # A rejected request (bad key, out of credit, unknown model) also arrives
        # as one JSON object — but an error, not a message. The SSE parser finds
        # no deltas, so without this the turn finalizes as an empty reply and the
        # UI blames the user's phrasing while the provider's actual complaint is
        # thrown away. Raise instead: the runner records it on the run and on the
        # message metadata.
        if parsed.is_a?(Hash) && parsed["type"] == "error"
          detail = parsed.dig("error", "message").to_s.presence ||
                   parsed.dig("error", "type").to_s.presence ||
                   raw.to_s.truncate(300)
          raise LlmError, "Anthropic API error: #{detail}"
        end

        Array(parsed&.dig("content")).each do |part|
          case part["type"]
          when "text"
            text = part["text"].to_s
            next if text.empty?

            full_content << text
            yield(full_content, full_content, tool_calls) if block_given?
          when "tool_use"
            tool_calls << {
              id: part["id"],
              type: "function",
              function: { name: part["name"], arguments: part["input"].to_json }
            }
          end
        end
      end

      { content: full_content, tool_calls: tool_calls, tokens: estimate_tokens(full_content) }
    end

    def sync_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, **)
      body = build_request_body(messages, tools, temperature, max_tokens, top_p)

      response = HTTParty.post("#{BASE_URL}/messages",
        headers: headers,
        body: body.to_json,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
      )

      unless response.success?
        raise LlmError, "Anthropic API error: #{response.code} - #{response.body}"
      end

      data = JSON.parse(response.body)
      content = ""
      tool_calls = []

      data["content"].each do |block|
        case block["type"]
        when "text"
          content << block["text"]
        when "tool_use"
          tool_calls << {
            id: block["id"],
            type: "function",
            function: {
              name: block["name"],
              arguments: block["input"].to_json
            }
          }
        end
      end

      {
        content: content,
        tool_calls: tool_calls,
        tokens: data.dig("usage", "output_tokens") || estimate_tokens(content),
        finish_reason: data.dig("stop_reason") || "stop"
      }
    end

    def embeddings(text)
      # Anthropic doesn't have a native embeddings endpoint.
      # Use OpenAI-compatible embedding endpoint or a local model.
      raise NotImplementedError, "Use OpenAI or a local model for embeddings"
    end

    private

    def build_request_body(messages, tools, temperature, max_tokens, top_p = nil)
      system_message = messages.find { |m| m[:role] == "system" }
      chat_messages = messages.reject { |m| m[:role] == "system" }

      body = {
        model: model,
        messages: format_messages(chat_messages),
        temperature: temperature,
        max_tokens: max_tokens
      }
      body[:top_p] = top_p unless top_p.nil?
      body[:system] = system_message[:content] if system_message
      body[:tools] = format_tools(tools) if tools.any?

      body
    end

    def format_messages(messages)
      messages.map do |msg|
        { role: msg[:role], content: msg[:content].to_s }
      end
    end

    def format_tools(tools)
      tools.map do |tool|
        {
          name: tool[:name],
          description: tool[:description] || "",
          input_schema: tool[:parameters] || { type: "object", properties: {}, required: [] }
        }
      end
    end

    def headers
      {
        "x-api-key" => api_key,
        "anthropic-version" => "2024-02-01",
        "content-type" => "application/json"
      }
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    class LlmError < StandardError; end
  end
end
