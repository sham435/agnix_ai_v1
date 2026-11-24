# frozen_string_literal: true

module Integrations
  module Github
    # Tool invocation can request review, but can never authorize a write.
    class CreateIssue
      def self.call(integration:, arguments:, context: {})
        Approval.call(action: :request, integration: integration, arguments: arguments, context: context)
      end
    end
  end
end
