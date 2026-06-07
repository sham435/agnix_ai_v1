require_relative "../boot"

Rails.application.configure do
  # Production-specific settings.
  config.log_level = :info

  # Eager load code for performance.
  config.eager_load = true

  # Full error reports.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for max performance.
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{1.year.to_i}",
    "Expires" => 1.year.from_now.to_fs(:rfc822)
  }

  # Compress JavaScripts and CSS.
  config.assets.css_compressor = nil

  # Do not fallback to assets pipeline if a precompiled asset is missing.
  config.assets.unknown_asset_fallback = false

  # Assume all access from the app are happening over a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force HTTPS.
  config.force_ssl = true

  # Log to STDOUT with the current request id.
  config.log_tags = [:request_id]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Use a different cache store in production.
  config.cache_store = :solid_cache_store

  # Use a real queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Action Cable via Solid Cable in production.
  config.action_cable.cable = { adapter: "solid_cable" }

  # Enable locale fallbacks for I18n.
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # Info include generic and useful information about system operation.
  # Use a different logger for distributed setups.
  # require "syslog/logger"
  # config.logger = ActiveSupport::TaggedLogging.new(Syslog::Logger.new "app-name")

  # Mailer.
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST") }
  config.action_mailer.delivery_method = :postmark
  config.action_mailer.perform_deliveries = true

  # Use HTTPS in production.
  config.force_ssl = true

  # Secure cookies.
  config.session_store :cookie_store,
    key: "_agnix_session",
    same_site: :lax,
    secure: Rails.env.production?

  # Default URL options.
  config.default_url_options = { host: ENV.fetch("APP_HOST") }
end
