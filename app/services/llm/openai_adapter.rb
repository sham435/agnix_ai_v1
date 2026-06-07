# OpenAI API adapter.
# API docs: https://platform.openai.com/docs/api-reference/chat
module Llm
  class OpenaiAdapter
    BASE_URL = "https://api.openai.com/v1"

    attr_reader :api_key, :model, :base_url

    def initialize(api_key:, model:, base_url: nil)
      @api_key = api_key
      @model = model
      @base_url = base_url || BASE_URL
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
      body[:stream_options] = { include_usage: true }

      full_content = +""
      tool_calls = []

      HTTParty.post("#{base_url}/chat/completions",
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
            choice = event.dig("choices", 0)
            next unless choice

            delta = choice["delta"]
            if delta["content"]
              full_content << delta["content"]
              yield(delta["content"], full_content, tool_calls) if block_given?
            end

            if delta["tool_calls"]
              delta["tool_calls"].each do |tc|
                if tc["index"] && tool_calls[tc["index"]]
                  tool_calls[tc["index"]][:function][:arguments] << tc.dig("function", "arguments").to_s
                else
                  tool_calls << {
                    id: tc["id"],
                    type: "function",
                    function: { name: tc.dig("function", "name"), arguments: tc.dig("function", "arguments").to_s }
                  }
                end
              end
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

      response = HTTParty.post("#{base_url}/chat/completions",
        headers: headers,
        body: body.to_json
      )

      unless response.success?
        raise LlmError, "OpenAI API error: #{response.code} - #{response.body}"
      end

      data = JSON.parse(response.body)
      choice = data.dig("choices", 0, "message")

      raw_tool_calls = choice["tool_calls"] || []

      tool_calls = raw_tool_calls.map do |tc|
        { id: tc["id"], type: "function", function: tc["function"] }
      end

      {
        content: choice["content"] || "",
        tool_calls: tool_calls,
        tokens: data.dig("usage", "completion_tokens") || estimate_tokens(choice["content"]),
        finish_reason: data.dig("choices", 0, "finish_reason") || "stop"
      }
    end

    def embeddings(text)
      response = HTTParty.post("#{base_url}/embeddings",
        headers: headers,
        body: { model: "text-embedding-3-small", input: text, encoding_format: "float" }.to_json
      )

      unless response.success?
        raise LlmError, "OpenAI Embedding error: #{response.code}"
      end

      data = JSON.parse(response.body)
      data.dig("data", 0, "embedding")
    end

    private

    def build_request_body(messages, tools, temperature, max_tokens)
      body = {
        model: model,
        messages: messages.map { |m| { role: m[:role], content: m[:content].to_s } },
        temperature: temperature,
        max_tokens: max_tokens
      }

      if tools.any?
        body[:tools] = tools.map do |tool|
          {
            type: "function",
            function: {
              name: tool[:name],
              description: tool[:description] || "",
              parameters: tool[:parameters] || { type: "object", properties: {}, required: [] }
            }
          }
        end
      end

      body
    end

    def headers
      {
        "Authorization" => "Bearer #{api_key}",
        "Content-Type" => "application/json"
      }
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    class LlmError < StandardError; end
  end
end
