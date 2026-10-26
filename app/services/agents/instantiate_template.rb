# frozen_string_literal: true

# Phase 5b — Materializes an Explore template as a real Agent inside the
# current organization. Idempotent by (organization, slug): the Agent model
# validates slug uniqueness per org, so a second "Start chat" on the same
# template returns the existing row instead of duplicating it.
module Agents
  module InstantiateTemplate
    class << self
      # Raises ActiveRecord::RecordNotFound for unknown slugs; the controller
      # answers 404 — an advertised-but-unknown template is a bug, not user
      # error, and must never silently create something arbitrary.
      def call(slug:, organization:)
        template = Agents::Templates.find(slug) or raise(ActiveRecord::RecordNotFound, "Unknown agent template #{slug}")
        find_or_create(template, organization)
      end

      private

      def find_or_create(template, organization)
        existing = organization.agents.find_by(slug: template[:slug])
        return existing if existing

        begin
          Agents::Templates.to_agent(template, organization: organization).tap(&:save!)
        rescue ActiveRecord::RecordNotUnique
          # Lost a race against a concurrent start for the same slug — the
          # winning row is exactly what we would have created.
          organization.agents.find_by!(slug: template[:slug])
        end
      end
    end
  end
end
