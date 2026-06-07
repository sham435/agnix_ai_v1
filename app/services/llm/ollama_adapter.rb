# Ollama local LLM adapter.
# API docs: https://github.com/ollama/ollama/blob/main/docs/api.md
module Llm
  class OllamaAdapter
    BASE_URL = ENV.fetch("OLLAMA_HOST", "http://localhost:11434")

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
      body = {
        model: model,
        messages: messages.map { |m| { role: m[:role], content: m[:content].to_s } },
        temperature: temperature,
        stream: true,
        options: { num_predict: max_tokens }
      }

      full_content = +""
      response = HTTParty.post("#{BASE_URL}/api/chat",
        headers: { "Content-Type" => "application/json" },
        body: body.to_json,
        stream_body: true
      ) do |chunk|
        chunk.to_s.each_line do |line|
          begin
            data = JSON.parse(line)
            content = data.dig("message", "content")
            if content
              full_content << content
              yield(content, full_content, []) if block_given?
            end
          rescue JSON::ParserError
            next
          end
        end
      end

      { content: full_content, tool_calls: [], tokens: estimate_tokens(full_content) }
    end

    def sync_chat(messages:, tools:, temperature:, max_tokens:, **)
      body = {
        model: model,
        messages: messages.map { |m| { role: m[:role], content: m[:content].to_s } },
        temperature: temperature,
        stream: false,
        options: { num_predict: max_tokens }
      }

      response = HTTParty.post("#{BASE_URL}/api/chat",
        headers: { "Content-Type" => "application/json" },
        body: body.to_json
      )

      unless response.success?
        raise LlmError, "Ollama error: #{response.code} - #{response.body}"
      end

      data = JSON.parse(response.body)
      content = data.dig("message", "content") || ""

      {
        content: content,
        tool_calls: [],
        tokens: estimate_tokens(content),
        finish_reason: data["done_reason"] || "stop"
      }
    end

    def embeddings(text)
      response = HTTParty.post("#{BASE_URL}/api/embed",
        headers: { "Content-Type" => "application/json" },
        body: { model: model, input: text }.to_json
      )

      return nil unless response.success?
      JSON.parse(response.body).dig("embeddings", 0)
    end

    private

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    class LlmError < StandardError; end
  end
end
