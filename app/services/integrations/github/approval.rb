# frozen_string_literal: true

require "httparty"
require "cgi"
require "digest"

module Integrations
  module Github
    # Dedicated tool Message rows avoid sharing mutable runner checkpoints.
    # A committed claim precedes network I/O: crashes leave an uncertain,
    # consumed operation, never an automatically retried provider write.
    class Approval
      extend Integrations::HttpSupport

      TTL = 10.minutes
      KEY = "github_write_approval"
      PURPOSE = "github.create_issue.approval.v1"

      def self.call(action:, integration: nil, arguments: {}, context: {}, user: nil, token: nil)
        case action
        when :request then request_approval(integration, arguments, context)
        when :inspect then inspect_approval(user, token)
        when :confirm then confirm(user, token)
        else { ok: false, error_code: "invalid_request" }
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound, ArgumentError, KeyError, TypeError
        { ok: false, error_code: action == :request ? "invalid_request" : "approval_unavailable" }
      end

      class << self
        private

        def verifier
          Rails.application.message_verifier(PURPOSE)
        end

        def canonical(arguments)
          raise ArgumentError unless arguments.is_a?(Hash)

          args = arguments.stringify_keys
          raise ArgumentError unless (args.keys - %w[owner repo title body labels]).empty?

          result = %w[owner repo title].to_h { |key| [ key, args[key].to_s.strip ] }
          raise ArgumentError unless result.values.all?(&:present?)
          raise ArgumentError unless result.values_at("owner", "repo").all? { |v| v.match?(/\A[a-zA-Z0-9_.-]{1,100}\z/) }
          raise ArgumentError if result["title"].bytesize > 256

          if args["body"].present?
            raise ArgumentError unless args["body"].is_a?(String) && args["body"].bytesize <= 20_000

            result["body"] = args["body"]
          end
          if args["labels"].present?
            labels = args["labels"]
            raise ArgumentError unless labels.is_a?(Array) && labels.size <= 20 &&
              labels.all? { |label| label.is_a?(String) && label.bytesize.between?(1, 100) }

            result["labels"] = labels
          end
          result.sort.to_h
        end

        def digest(binding)
          Digest::SHA256.hexdigest(sorted_json(binding).to_json)
        end

        def sorted_json(value)
          case value
          when Hash then value.sort.to_h.transform_values { |item| sorted_json(item) }
          when Array then value.map { |item| sorted_json(item) }
          else value
          end
        end

        def authorized?(user, conversation, integration)
          user.is_a?(User) && conversation.user_id == user.id &&
            integration.provider == "github" && integration.is_active? &&
            conversation.agent.organization_id == integration.organization_id &&
            ToolIntegration.authorized_organization_for(user, agent_id: conversation.agent_id)&.id == integration.organization_id
        end

        def request_approval(integration, arguments, context)
          user = context[:user] || User.find_by(id: context[:user_id])
          conversation = Conversation.find_by(id: context[:conversation_id])
          return { ok: false, error_code: "forbidden" } unless conversation && integration &&
            context[:agent_id].to_s == conversation.agent_id && authorized?(user, conversation, integration)
          return { ok: false, error_code: "forbidden" } if context[:user_id].present? && context[:user_id].to_s != user.id

          binding = {
            "operation" => "github.create_issue", "arguments" => canonical(arguments),
            "user_id" => user.id, "organization_id" => integration.organization_id,
            "integration_id" => integration.id, "conversation_id" => conversation.id,
            "agent_id" => conversation.agent_id, "expires_at" => TTL.from_now.utc.iso8601(6),
            "nonce" => SecureRandom.hex(32)
          }
          row = conversation.messages.create!(role: :tool, content: "GitHub issue creation awaiting explicit confirmation.",
            metadata: { KEY => { "binding" => binding, "state" => "pending", "audit" => [ event("requested") ] } })
          token = verifier.generate({ "id" => row.id, "digest" => digest(binding) }, purpose: PURPOSE)
          { ok: false, error_code: "approval_required",
            approval_url: Rails.application.routes.url_helpers.github_approval_path(token: token) }
        end

        def load_approval(user, token)
          signed = verifier.verify(token.to_s, purpose: PURPOSE)
          row = Message.find(signed.fetch("id"))
          data = row.metadata.fetch(KEY)
          binding = data.fetch("binding")
          integration = ToolIntegration.find(binding.fetch("integration_id"))
          raise ArgumentError unless digest(binding) == signed["digest"] && binding["user_id"] == user&.id &&
            binding["conversation_id"] == row.conversation_id && binding["agent_id"] == row.conversation.agent_id &&
            binding["organization_id"] == integration.organization_id && authorized?(user, row.conversation, integration)

          [ row, integration, binding ]
        end

        def available?(data)
          data["state"] == "pending" && Time.iso8601(data.fetch("binding").fetch("expires_at")) > Time.current
        end

        def inspect_approval(user, token)
          row, _integration, binding = load_approval(user, token)
          return { ok: false, error_code: "approval_unavailable" } unless available?(row.metadata.fetch(KEY))

          { ok: true, binding: binding }
        end

        def event(state, extra = {})
          { "state" => state, "at" => Time.current.utc.iso8601(6) }.merge(extra)
        end

        def confirm(user, token)
          row, integration, binding = load_approval(user, token)
          claimed = false
          row.with_lock do
            data = row.metadata.fetch(KEY).deep_dup
            if available?(data) && digest(data["binding"]) == digest(binding)
              data["state"] = "consumed"
              data["audit"] << event("confirmed", "user_id" => user.id)
              data["audit"] << event("attempted")
              row.update_column(:metadata, row.metadata.merge(KEY => data))
              claimed = true
            end
          end
          return { ok: false, error_code: "approval_unavailable" } unless claimed

          result = execute(integration, binding.fetch("arguments"))
          row.with_lock do
            data = row.metadata.fetch(KEY).deep_dup
            data["audit"] << event(result[:ok] ? "succeeded" : "failed",
              "error_code" => result[:error_code], "issue_number" => result[:issue_number]).compact
            row.update_column(:metadata, row.metadata.merge(KEY => data))
          end
          result
        end

        # Private executor has no approval flag/token argument and is not a tool.
        def execute(integration, args)
          return { ok: false, error_code: "missing_credentials" } if integration.api_key.blank?

          response = HTTParty.post(
            "https://api.github.com/repos/#{CGI.escape(args.fetch('owner'))}/#{CGI.escape(args.fetch('repo'))}/issues",
            headers: bearer_headers(integration.api_key, {
              "Accept" => "application/vnd.github+json", "X-GitHub-Api-Version" => "2022-11-28"
            }), body: args.except("owner", "repo").to_json, timeout: timeout_for(integration)
          )
          parsed = parse_json(response)
          if http_ok?(response.code) && parsed["number"].is_a?(Integer)
            { ok: true, issue_number: parsed["number"] }
          else
            { ok: false, error_code: "provider_error" }
          end
        rescue StandardError
          # Provider bodies/exceptions can echo credentials or sensitive content.
          { ok: false, error_code: "request_failed" }
        end
      end
    end
  end
end
