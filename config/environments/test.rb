require_relative "../boot"

Rails.application.configure do
  config.log_level = :debug

  # Eager load code for performance.
  config.eager_load = true

  # Full error reports.
  config.consider_all_requests_local = true

  # Disable caching.
  config.action_controller.perform_caching = false

  # Run jobs synchronously for system specs.
  config.active_job.queue_adapter = :inline

  # Action Cable.
  config.action_cable.cable = { adapter: "test" }

  # Mailer.
  config.action_mailer.delivery_method = :test
  config.action_mailer.default_url_options = { host: "example.com" }

  # Raise error on missing translations.
  config.i18n.raise_on_missing_translations = true

  # Raise on unpermitted params.
  config.active_support.report_deprecations = false

  # Raise on disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Annotations.
  config.active_record.verbose_query_logs = true

  # Raises error for missing translations.
  config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true
end
