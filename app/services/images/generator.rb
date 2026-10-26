# frozen_string_literal: true

require "httparty"

module Images
  # OpenAI Images API adapter (Phase 3). Reuses the LLM client's conventions:
  # the same server-side key loading idiom (Rails credentials :openai/:api_key
  # falling back to OPENAI_API_KEY), HTTParty with explicit open/read timeouts,
  # and transport-transient retries with linear backoff. No new env var names.
  #
  # Provider quirks handled here (never in callers):
  # * gpt-image-1 always returns b64_json and REJECTS a response_format param —
  #   it is only sent for the dall-e-3 fallback.
  # * dall-e-3 does not accept "auto" quality/rectangular gpt-image sizes, so
  #   those are mapped to its own vocabulary before the request.
  class Generator
    BASE_URL = "https://api.openai.com/v1"
    IMAGE_PATH = "/images/generations"

    # Images take far longer than a chat token stream but still must not hang a
    # queue worker forever: 10s to open, 60s to read (spec: ~30-60s).
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 60

    MAX_ATTEMPTS = 2
    RETRY_BACKOFF_SECONDS = 2

    TRANSIENT_ERRORS = [
      Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, EOFError,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Net::HTTPBadResponse
    ].freeze

    TIMEOUT_ERRORS = [ Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout ].freeze

    GPT_IMAGE_MODEL = "gpt-image-1"
    FALLBACK_MODEL = "dall-e-3"

    # A single generated image plus the provider-side detail worth persisting.
    Image = Data.define(:b64_json, :revised_prompt, :provider_id)
    Result = Data.define(:images, :created, :model)

    class Error < StandardError; end

    class NotConfigured < Error
      def initialize(msg = "Image generation is not configured. Add an OpenAI API key.")
        super
      end
    end

    class << self
      # Same key + precedence as every other OpenAI-backed service in the app
      # (Llm::Client, EmbeddingService): credentials first, then the env var.
      def api_key
        Rails.application.credentials.dig(:openai, :api_key) || ENV.fetch("OPENAI_API_KEY", "")
      end

      def configured?
        api_key.present?
      end
    end

    attr_reader :api_key, :model

    def initialize(api_key: nil, model: GPT_IMAGE_MODEL, base_url: BASE_URL)
      @api_key = api_key.presence || self.class.api_key
      @model = model.presence || GPT_IMAGE_MODEL
      @base_url = base_url
    end

    # Returns Result(images: [Image]); raises Error subclasses with readable,
    # user-facing messages on any provider failure. Never leaks raw bodies.
    def generate(prompt:, size: "1024x1024", quality: "auto", n: 1)
      raise NotConfigured if @api_key.blank?
      raise Error, "Image generation needs a prompt before it can run." if prompt.blank?

      body = build_body(prompt:, size:, quality:, n:)
      response = request_with_retries(body)
      parse(response)
    end

    private

    def build_body(prompt:, size:, quality:, n:)
      body = { model: @model, prompt: prompt, size: size, quality: quality, n: n }
      if @model == GPT_IMAGE_MODEL
        body[:quality] = "auto" if body[:quality].blank?
      else
        body.merge!(fallback_body_adjustments(body))
      end
      # gpt-image-1 returns b64_json unconditionally and errors on response_format.
      body[:response_format] = "b64_json" unless @model == GPT_IMAGE_MODEL
      body
    end

    # dall-e-3 vocabulary: standard|hd quality and its own rectangular sizes.
    def fallback_body_adjustments(body)
      adjustments = {}
      adjustments[:quality] = "standard" if %w[auto low medium high].include?(body[:quality])
      case body[:size]
      when "1024x1536" then adjustments[:size] = "1024x1792"
      when "1536x1024" then adjustments[:size] = "1792x1024"
      when "auto" then adjustments[:size] = "1024x1024"
      end
      adjustments[:n] = 1 if body[:n].to_i > 1
      body.merge(adjustments)
    end

    def request_with_retries(body)
      attempt = 0
      begin
        attempt += 1
        post_json(body)
      rescue *TRANSIENT_ERRORS => e
        if attempt >= MAX_ATTEMPTS
          raise Error, TIMEOUT_ERRORS.any? { |k| e.is_a?(k) } ?
            "Image generation timed out waiting for the provider. Try again." :
            "Could not reach the image provider (#{e.class}). Try again."
        end

        sleep(RETRY_BACKOFF_SECONDS * attempt)
        retry
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "Could not reach the image provider: #{e.message}"
      end
    end

    def post_json(body)
      response = HTTParty.post("#{@base_url}#{IMAGE_PATH}",
                               body: body.to_json,
                               headers: request_headers,
                               timeout: READ_TIMEOUT,
                               open_timeout: OPEN_TIMEOUT)
      check_response!(response)
      response
    end

    def request_headers
      {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type" => "application/json"
      }
    end

    def check_response!(response)
      code = response.code.to_i
      return response if code.between?(200, 299)

      message = provider_error_message(response)
      raise Error, case code
      when 401 then "The OpenAI API key was rejected. Update it in Settings."
      when 403 then "This OpenAI account is not allowed to generate images."
      when 429 then "Image generation is rate limited right now; try again in a moment."
      when 400..499 then "The image provider rejected the request: #{message}"
      else "The image provider is unavailable (HTTP #{code}). Try again later."
      end
    end

    def provider_error_message(response)
      parsed = JSON.parse(response.body.to_s)
      parsed.dig("error", "message").presence || parsed["message"].presence || "unexpected error"
    rescue JSON::ParserError
      "unexpected error"
    end

    def parse(response)
      payload = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Error, "The image provider returned an unreadable response."
      end

      items = Array(payload["data"])
      raise Error, "The image provider returned no images." if items.empty?

      Result.new(
        images: items.map { |item|
          Image.new(b64_json: item["b64_json"].to_s,
                    revised_prompt: item["revised_prompt"],
                    provider_id: item["id"])
        },
        created: payload["created"],
        model: @model
      )
    end
  end
end
