# frozen_string_literal: true

module Api
  module V1
    module Openai
      class ChatCompletionsController < ApplicationController
        # OpenAI-compatible completions gateway for OpenCode.
        # Stateless proxy to the local Bonsai llama.cpp server.
        # Same session policy as every other API v1 endpoint: an unauthenticated
        # caller must never reach the model behind it.
        before_action :authenticate_user!

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
              status = upstream.code.to_i
              if status.between?(400, 599)
                Rails.logger.warn("[OpenAI Gateway] upstream returned HTTP #{status}")
                response.status = status
                response.headers["Content-Type"] = "application/json"
                response.stream.write(gateway_error.to_json)
                break
              end
              upstream.read_body do |chunk|
                next if chunk.nil? || chunk.empty?
                response.stream.write(chunk)
                break if chunk.include?("[DONE]")
              end
            end
            response.stream.close
          else
            resp = http.request(req)
            status = resp.code.to_i
            if status.between?(400, 599)
              Rails.logger.warn("[OpenAI Gateway] upstream returned HTTP #{status}")
              render json: gateway_error, status: status
            else
              render json: JSON.parse(resp.body), status: status
            end
          end
        rescue StandardError => e
          Rails.logger.error("[OpenAI Gateway] #{e.class}")
          begin
            response.stream.close
          rescue StandardError
            nil
          end
          render json: gateway_error, status: :bad_gateway
        end

        private

        def gateway_error
          { error: { message: "The model service could not complete the request.",
                     type: "server_error", code: "upstream_error" } }
        end

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
