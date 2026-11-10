# frozen_string_literal: true

module Api
  module V1
    module Openai
      class ChatCompletionsController < ActionController::API
        # OpenAI-compatible completions gateway for OpenCode.
        # Stateless proxy to the local Bonsai llama.cpp server.
        # No authentication for local dev.

        def models
          models = [
            {
              id: ENV.fetch("BONSAI_MODEL", "bonsai-2-27b"),
              object: "model",
              created: Time.now.to_i,
              owned_by: "shamsai"
            }
          ]
          render json: { object: "list", data: models }
        end

        def create
          bonsai_base = ENV.fetch("BONSAI2_BASE_URL", "http://127.0.0.1:8080/v1")
          uri = URI("#{bonsai_base}/chat/completions")

          # Build request body, forcing enable_thinking off for Bonsai.
          body = request_body
          body[:chat_template_kwargs] = { enable_thinking: false }

          stream = params[:stream] == true || params[:stream] == "true"

          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = 10
          http.read_timeout = 600

          req = Net::HTTP::Post.new(uri.request_uri, { "Content-Type" => "application/json" })
          req.body = body.to_json

          if stream
            self.response.headers["Content-Type"] = "text/event-stream"
            self.response.headers["Cache-Control"] = "no-cache"
            self.response.headers["Connection"] = "keep-alive"
            self.response.headers["X-Accel-Buffering"] = "no"

            req["Connection"] = "close"
            http.request(req) do |upstream|
              upstream.read_body do |chunk|
                next if chunk.nil? || chunk.empty?
                response.stream.write(chunk)
                break if chunk.include?("[DONE]")
              end
            end
            response.stream.close
          else
            resp = http.request(req)
            render json: JSON.parse(resp.body), status: resp.code.to_i
          end
        rescue StandardError => e
          Rails.logger.error("[OpenAI Gateway] #{e.class}: #{e.message}")
          begin
            response.stream.close
          rescue StandardError
            nil
          end
          render json: { error: { message: e.message, type: "server_error", code: 500 } }, status: :internal_server_error
        end

        private

        def request_body
          model = params[:model] || ENV.fetch("BONSAI_MODEL", "bonsai-2-27b")
          messages = params[:messages] || []
          max_tokens = params[:max_tokens] || params[:max_completion_tokens]
          temperature = params[:temperature]
          top_p = params[:top_p]

          body = {
            model: model,
            messages: messages,
            stream: params[:stream] == true || params[:stream] == "true",
            max_tokens: max_tokens,
            temperature: temperature,
            top_p: top_p
          }.compact
          body
        end
      end
    end
  end
end
