# frozen_string_literal: true

module Api
  module V1
    # Single source of truth for which capabilities the client may render.
    # No hardcoded client-side feature list — the composer/tool menu reads
    # exactly this response.
    class CapabilitiesController < ApplicationController
      before_action :authenticate_user!

      def index
        render json: { capabilities: Capabilities::Registry.index }
      end
    end
  end
end
