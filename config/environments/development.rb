require_relative "../boot"

Rails.application.configure do
  # Verify credentials digest.
  config.after_initialize do
    Rails.application.credentials.key_path = Rails.root.join("config/credentials/development.key")
  end

  # Settings specified here will override any global settings.
  # Print deprecation notices to the Rails logger.
  config.log_level = :debug

  # Eager load only when needed.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Use memory store so sessions are cleared on server restart.
  config.cache_store = :memory_store

  # Enable/disable Action Controller caching.
  config.action_controller.perform_caching = false

  # Enable/disable Action Mailer previews.
  config.action_mailer.perform_caching = false

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Use a regular file watcher (no listen gem needed).
  config.file_watcher = ActiveSupport::FileUpdateChecker

  # Run jobs inline so streaming works without a separate worker process.
  config.active_job.queue_adapter = :inline

  # Dev mailer.
  config.action_mailer.delivery_method = :letter_opener
  config.action_mailer.perform_deliveries = true
  config.action_mailer.default_url_options = { host: "localhost", port: 3001 }

  # Allow requests from localhost.
  config.hosts << /.*\.local/
  config.hosts << "localhost"
  config.hosts << "127\.0\.0\.1"
end
