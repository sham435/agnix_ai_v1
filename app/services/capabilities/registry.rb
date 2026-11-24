# frozen_string_literal: true

require "json_schemer"

module Capabilities
  # Single source of truth for capability availability. The frontend renders
  # exactly this registry (GET /api/v1/capabilities) — no hardcoded
  # client-side feature list. Every capability carries labeled metadata,
  # typed input/output schemas, execution limits, async flag, renderer info,
  # and an honest availability state derived from real configuration
  # presence (never assumed available without credentials).
  class Registry
    STATES = %w[enabled disabled needs_authorization].freeze

    WEB_SEARCH_KEY_ENV = "SHAMS_WEB_SEARCH_API_KEY"
    WEB_SEARCH_KEY_CREDENTIALS = %i[web_search api_key].freeze

    # Image generation (Phase 3) reuses the app's existing OpenAI key — same
    # precedence as Llm::Client / Images::Generator. No new env var names.
    OPENAI_IMAGE_KEY_ENV = "OPENAI_API_KEY"
    OPENAI_IMAGE_KEY_CREDENTIALS = %i[openai api_key].freeze

    DEFINITIONS = [
      {
        key: "chat",
        label: "Chat",
        description: "Send messages and receive agent responses.",
        state_fn: ->(_r) { [ :enabled, nil ] },
        async: false,
        input_schema: {
          "type" => "object",
          "properties" => { "content" => { "type" => "string", "minLength" => 1 } },
          "required" => [ "content" ]
        },
        output_schema: { "type" => "object", "properties" => { "message" => { "type" => "object" } } },
        execution_limits: { max_tokens: nil },
        renderer: "chat"
      },
      {
        key: "attachments",
        label: "Attachments",
        description: "Attach images, PDF, DOCX, XLSX, CSV and text files to messages.",
        state_fn: ->(_r) { [ :enabled, nil ] },
        async: true,
        input_schema: {
          "type" => "object",
          "properties" => { "file" => { "type" => "string", "format" => "binary" } },
          "required" => [ "file" ]
        },
        output_schema: {
          "type" => "object",
          "properties" => { "asset" => { "type" => "object" }, "extraction" => { "type" => "object" } }
        },
        execution_limits: { max_file_bytes: Assets::Validator::MAX_SIZE, max_image_bytes: Assets::Validator::MAX_IMAGE_SIZE },
        renderer: "attachment_chip"
      },
      {
        key: "library",
        label: "Library",
        description: "Reuse previously uploaded assets without duplicating bytes.",
        state_fn: ->(_r) { [ :enabled, nil ] },
        async: false,
        input_schema: { "type" => "object", "properties" => { "asset_id" => { "type" => "string" } } },
        output_schema: { "type" => "object", "properties" => { "items" => { "type" => "array" } } },
        execution_limits: {},
        renderer: "library_list"
      },
      {
        key: "file_extraction",
        label: "File extraction",
        description: "Extract text/tables from PDF, DOCX, XLSX and CSV into bounded content.",
        state_fn: ->(_r) { [ :enabled, nil ] },
        async: true,
        input_schema: { "type" => "object", "properties" => { "asset_id" => { "type" => "string" } } },
        output_schema: { "type" => "object", "properties" => { "status" => { "type" => "string" }, "meta" => { "type" => "object" } } },
        execution_limits: { max_content_chars: Assets::Extractors::BOUNDED_CONTENT_CHARS, ocr: false },
        renderer: "extraction_status"
      },
      {
        key: "thinking",
        label: "Thinking effort",
        description: "Effort selector (auto/low/medium/high) passed only when the model supports it.",
        state_fn: ->(_r) { [ :enabled, nil ] },
        async: false,
        input_schema: {
          "type" => "object",
          "properties" => { "effort" => { "enum" => %w[auto low medium high] } },
          "required" => [ "effort" ]
        },
        output_schema: { "type" => "object", "properties" => { "applied" => { "type" => "boolean" } } },
        execution_limits: {},
        renderer: "effort_selector"
      },
      {
        key: "web_search",
        label: "Web search",
        description: "Search the web through a provider adapter with real, cited sources.",
        state_fn: ->(r) { r.web_search_configured? ? [ :enabled, nil ] : [ :needs_authorization, "not_configured" ] },
        async: false,
        input_schema: {
          "type" => "object",
          "properties" => { "query" => { "type" => "string", "minLength" => 1, "maxLength" => 512 } },
          "required" => [ "query" ]
        },
        output_schema: { "type" => "object", "properties" => { "sources" => { "type" => "array", "items" => { "type" => "object" } } } },
        execution_limits: { max_sources: 10 },
        renderer: "source_citations"
      },
      {
        key: "webfetch",
        label: "Webfetch",
        description: "Fetch a public HTTP(S) page as bounded, untrusted markdown, text, HTML, JSON, or XML content.",
        state_fn: ->(_r) { [ :enabled, nil ] },
        async: false,
        input_schema: {
          "type" => "object",
          "additionalProperties" => false,
          "properties" => {
            "url" => { "type" => "string", "minLength" => 1, "maxLength" => 2_048 },
            "format" => { "type" => "string", "enum" => %w[markdown text html], "default" => "markdown" },
            "timeout" => { "type" => "integer", "minimum" => 1, "maximum" => 120, "default" => 20 }
          },
          "required" => [ "url" ]
        },
        output_schema: {
          "type" => "object",
          "properties" => {
            "content" => { "type" => "string" },
            "format" => { "type" => "string" },
            "final_url" => { "type" => "string" },
            "content_type" => { "type" => "string" },
            "truncated" => { "type" => "boolean" },
            "untrusted" => { "type" => "boolean" }
          }
        },
        execution_limits: { timeout_seconds: 20, max_response_bytes: WebfetchService::MAX_RESPONSE_BYTES,
                            max_output_bytes: WebfetchService::MAX_OUTPUT_BYTES, max_redirects: WebfetchService::MAX_REDIRECTS },
        renderer: "web_content"
      },
      {
        key: "deep_research",
        label: "Deep research",
        description: "Multi-step research run with source/call/time budgets and deduplicated citations.",
        state_fn: ->(r) { r.web_search_configured? ? [ :enabled, nil ] : [ :disabled, "depends:web_search" ] },
        async: true,
        input_schema: { "type" => "object", "properties" => { "topic" => { "type" => "string", "minLength" => 1 } }, "required" => [ "topic" ] },
        output_schema: { "type" => "object", "properties" => { "status" => { "type" => "string" }, "sources" => { "type" => "array" } } },
        execution_limits: { source_budget: 10, call_budget: 20, time_budget_seconds: 120, cancellable: true },
        renderer: "research_progress"
      },
      {
        key: "image_generation",
        label: "Image generation",
        description: "Generate images through a provider adapter; results become assets.",
        state_fn: ->(r) { r.openai_image_key_configured? ? [ :enabled, nil ] : [ :needs_authorization, "not_configured" ] },
        async: true,
        input_schema: { "type" => "object", "properties" => { "prompt" => { "type" => "string", "minLength" => 1 } }, "required" => [ "prompt" ] },
        output_schema: { "type" => "object", "properties" => { "asset_id" => { "type" => "string" }, "image_generation_id" => { "type" => "string" }, "status" => { "type" => "string" } } },
        execution_limits: { images_per_call: 1 },
        renderer: "image_result"
      },
      {
        key: "sketch",
        label: "Sketch",
        description: "Draw a reproducible SVG/JSON sketch with PNG preview.",
        state_fn: ->(_r) { Sketches::Create.available? ? [ :enabled, nil ] : [ :disabled, "renderer_unavailable" ] },
        async: false,
        input_schema: {
          "type" => "object", "required" => [ "document" ],
          "properties" => { "document" => { "type" => "object" } }
        },
        output_schema: { "type" => "object", "properties" => { "asset_id" => { "type" => "string" } } },
        execution_limits: {},
        renderer: "sketch_canvas"
      },
      {
        key: "github",
        label: "GitHub",
        description: "Read-only GitHub operations first; writes require explicit confirmation + audit.",
        state_fn: ->(_r) { [ :needs_authorization, "requires_connection" ] },
        async: false,
        input_schema: { "type" => "object", "properties" => { "operation" => { "type" => "string" } } },
        output_schema: { "type" => "object", "properties" => { "result" => { "type" => "object" } } },
        execution_limits: { external_writes: false },
        renderer: "integration_result"
      },
      {
        key: "notion",
        label: "Notion",
        description: "Read-only Notion operations first; writes require explicit confirmation + audit.",
        state_fn: ->(_r) { [ :needs_authorization, "requires_connection" ] },
        async: false,
        input_schema: { "type" => "object", "properties" => { "operation" => { "type" => "string" } } },
        output_schema: { "type" => "object", "properties" => { "result" => { "type" => "object" } } },
        execution_limits: { external_writes: false },
        renderer: "integration_result"
      },
      {
        key: "figma",
        label: "Figma",
        description: "Read Figma files with bounded depth. Read-only; no writes supported.",
        state_fn: ->(_r) { [ :needs_authorization, "requires_connection" ] },
        async: false,
        input_schema: { "type" => "object", "properties" => { "operation" => { "type" => "string" } } },
        output_schema: { "type" => "object", "properties" => { "result" => { "type" => "object" } } },
        execution_limits: { external_writes: false },
        renderer: "integration_result"
      },
      {
        key: "openai_model",
        label: "OpenAI",
        description: "Bring-your-own-key server-side model adapter; disabled until configured.",
        state_fn: ->(_r) { [ :needs_authorization, "requires_connection" ] },
        async: false,
        input_schema: { "type" => "object", "properties" => { "prompt" => { "type" => "string" } } },
        output_schema: { "type" => "object", "properties" => { "completion" => { "type" => "string" } } },
        execution_limits: { external_writes: false },
        renderer: "integration_result"
      }
    ].freeze

    class UnknownCapability < StandardError; end

    class << self
      def index(organization: nil)
        DEFINITIONS.map { |definition| entry(definition, organization: organization) }
      end

      def find(key, organization: nil)
        definition = DEFINITIONS.find { |d| d[:key] == key.to_s }
        raise UnknownCapability, key.to_s if definition.nil?

        entry(definition, organization: organization)
      end

      def available?(key, organization: nil)
        find(key, organization: organization)[:state] == "enabled"
      end

      # Validates capability input against its typed schema (json_schemer).
      # Raises UnknownCapability for unknown keys; returns array of schema
      # validation errors; empty array when valid.
      def validate_input(key, input)
        errors = JSONSchemer.schema(find(key).fetch(:input_schema)).validate(input)
        errors.map(&:to_hash).map { |h| { pointer: h.fetch("data_pointer"), error: h.fetch("error") } }
      end

      def web_search_configured?(organization: nil)
        return false if ToolIntegration.connection_disabled?(organization, "web_search")

        connection_configured?(organization, "web_search") ||
          Rails.application.credentials.dig(*WEB_SEARCH_KEY_CREDENTIALS).present? ||
          ENV[WEB_SEARCH_KEY_ENV].present?
      end

      def connection_configured?(organization, provider)
        ToolIntegration.connection_for(organization, provider)&.api_key.present?
      end

      # Phase 3: the image_generation capability is a real availability check —
      # enabled exactly when the OpenAI key the generator would use exists.
      def openai_image_key_configured?
        Rails.application.credentials.dig(*OPENAI_IMAGE_KEY_CREDENTIALS).present? ||
          ENV[OPENAI_IMAGE_KEY_ENV].present?
      end

      private

      def entry(definition, organization: nil)
        state, reason = definition[:state_fn].call(self)
        if organization && %w[web_search deep_research].include?(definition[:key])
          if web_search_configured?(organization: organization)
            state, reason = :enabled, nil
          else
            state, reason = definition[:key] == "web_search" ? [ :needs_authorization, "not_configured" ] : [ :disabled, "depends:web_search" ]
          end
        elsif %w[figma github notion].include?(definition[:key]) && connection_configured?(organization, definition[:key])
          state, reason = :enabled, nil
        elsif definition[:key] == "openai_model" && connection_configured?(organization, "openai")
          state, reason = :enabled, nil
        elsif definition[:key] == "webfetch" && webfetch_organization_disabled?(organization)
          state, reason = :disabled, "organization_disabled"
        end

        {
          key: definition[:key],
          label: definition[:label],
          description: definition[:description],
          state: state.to_s,
          reason: reason&.to_s,
          async: definition[:async],
          requires_auth: true,
          input_schema: definition[:input_schema],
          output_schema: definition[:output_schema],
          execution_limits: definition[:execution_limits],
          renderer: definition[:renderer]
        }
      end

      def webfetch_organization_disabled?(organization)
        settings = organization&.settings
        return false unless settings.is_a?(Hash)

        capabilities = settings["capabilities"]
        return true if capabilities.is_a?(Hash) && (capabilities["webfetch"] == false || capabilities[:webfetch] == false)
        return true if Array(settings["disabled_capabilities"]).map(&:to_s).include?("webfetch")

        enabled = settings["enabled_capabilities"]
        enabled.is_a?(Array) && enabled.map(&:to_s).exclude?("webfetch")
      end
    end
  end
end
