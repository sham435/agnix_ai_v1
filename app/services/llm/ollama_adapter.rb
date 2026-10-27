# Ollama local LLM adapter.
# API docs: https://github.com/ollama/ollama/blob/main/docs/api.md
module Llm
  class OllamaAdapter
    BASE_URL = ENV.fetch("OLLAMA_HOST", "http://localhost:11434")

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 180 # Local model may take longer for large responses

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
      body = {
        model: model,
        messages: messages.map { |m| { role: m[:role], content: m[:content].to_s } },
        temperature: temperature,
        stream: true,
        options: { num_predict: max_tokens }
      }
      body[:options][:top_p] = top_p unless top_p.nil?

      full_content = +""
      response = HTTParty.post("#{BASE_URL}/api/chat",
        headers: { "Content-Type" => "application/json" },
        body: body.to_json,
        stream_body: true,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
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

    def sync_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, **)
      body = {
        model: model,
        messages: messages.map { |m| { role: m[:role], content: m[:content].to_s } },
        temperature: temperature,
        stream: false,
        options: { num_predict: max_tokens }
      }
      body[:options][:top_p] = top_p unless top_p.nil?

      response = HTTParty.post("#{BASE_URL}/api/chat",
        headers: { "Content-Type" => "application/json" },
        body: body.to_json,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
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
        body: { model: model, input: text }.to_json,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
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
