require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "solid_queue/engine"
require "solid_cable/engine"
require "solid_cache/engine"

Bundler.require(*Rails.groups)

module Agnix
  class Application < Rails::Application
    config.load_defaults 8.1

    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]
    config.i18n.default_locale = :en

    config.active_job.queue_adapter = :solid_queue

    config.action_cable.mount_path = "/cable"

    config.session_store :cache_store, key: "_agnix_session", same_site: :lax

    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
      g.test_framework :rspec, fixture: false
      g.fixture_replacement :factory_bot, dir: "spec/factories"
      g.view_specs false
      g.routing_specs false
    end

    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins "*"
        resource "/cable", headers: :any, credentials: false
      end
    end
  end
end
