# Sentry error tracking.
if Rails.application.credentials.dig(:sentry, :dsn)
  Sentry.init do |config|
    config.dsn = Rails.application.credentials.dig(:sentry, :dsn)
    config.breadcrumbs_logger = [:active_support_logger, :http_logger]
    config.traces_sample_rate = 0.1
    config.profiles_sample_rate = 0.1 if Rails.env.production?
    config.enabled_environments = %w[production]
    config.send_default_pii = false
  end
end
