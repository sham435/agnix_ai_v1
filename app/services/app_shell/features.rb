# frozen_string_literal: true

# Phase 1 app-shell feature flags.
#
# The ChatGPT-style sidebar reserves nav slots for later phases (Scheduled →
# /scheduled, Images → /images, Explore → /explore). Rather than ship dead links
# (forbidden by the project's definition-of-done), the shell renders a slot only
# once its route is actually mounted. Detection scans the drawn route set, so the
# flags go live automatically as later phases land their routes — no manual
# config change and no stale hardcoding.
#
# Lives under app/ (not an initializer) so Zeitwerk autoloads it and dev servers
# pick it up on reload without a boot restart.
module AppShell
  module Features
    # feature key => the path prefix whose presence enables it
    REQUIRED_PATHS = {
      scheduled: "/scheduled",
      images: "/images",
      explore: "/explore"
    }.freeze

    class << self
      def enabled?(name)
        prefix = REQUIRED_PATHS[name.to_sym]
        return false if prefix.nil?

        mounted?(prefix)
      end

      def disabled?(name) = !enabled?(name)

      private

      # Memoised per boot — the route table does not change at runtime.
      def mounted?(prefix)
        @mounted ||= {}
        return @mounted[prefix] if @mounted.key?(prefix)

        @mounted[prefix] = route_paths.any? { |p| p.match?(/\A#{Regexp.escape(prefix)}(\.|\(|\/|\z)/) }
      end

      def route_paths
        routes = Rails.application.routes.routes
        routes.map { |r| r.path.spec.to_s }
      rescue StandardError
        []
      end
    end
  end
end
