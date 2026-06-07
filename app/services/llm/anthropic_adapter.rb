# Anthropic Claude API adapter.
# API docs: https://docs.anthropic.com/en/api/messages
module Llm
  class AnthropicAdapter
    BASE_URL = "https://api.anthropic.com/v1"

    attr_reader :api_key, :model

    def initialize(api_key:, model:)
      @api_key = api_key
      @model = model
    end

    def chat(messages:, tools:, temperature:, max_tokens:, stream: false)
      if stream
        stream_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens)
      else
        sync_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens)
      end
    end

    def stream_chat(messages:, tools:, temperature:, max_tokens:, &block)
      body = build_request_body(messages, tools, temperature, max_tokens)
      body[:stream] = true

      full_content = +""
      tool_calls = []

      HTTParty.post("#{BASE_URL}/messages",
        headers: headers,
        body: body.to_json,
        stream_body: true
      ) do |chunk|
        chunk.to_s.each_line do |line|
          line = line.chomp
          next unless line.start_with?("data: ")
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

      { content: full_content, tool_calls: tool_calls, tokens: estimate_tokens(full_content) }
    end

    def sync_chat(messages:, tools:, temperature:, max_tokens:, **)
      body = build_request_body(messages, tools, temperature, max_tokens)

      response = HTTParty.post("#{BASE_URL}/messages",
        headers: headers,
        body: body.to_json
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

    def build_request_body(messages, tools, temperature, max_tokens)
      system_message = messages.find { |m| m[:role] == "system" }
      chat_messages = messages.reject { |m| m[:role] == "system" }

      body = {
        model: model,
        messages: format_messages(chat_messages),
        temperature: temperature,
        max_tokens: max_tokens
      }
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
