# Stripe configuration.
Rails.application.config.stripe = ActiveSupport::OrderedOptions.new
Rails.application.config.stripe.api_key = Rails.application.credentials.dig(:stripe, :secret_key) || ENV.fetch("STRIPE_SECRET_KEY", "")
Rails.application.config.stripe.webhook_secret = Rails.application.credentials.dig(:stripe, :webhook_secret) || ENV.fetch("STRIPE_WEBHOOK_SECRET", "")
Rails.application.config.stripe.publishable_key = Rails.application.credentials.dig(:stripe, :publishable_key) || ENV.fetch("STRIPE_PUBLISHABLE_KEY", "")

Stripe.api_key = Rails.application.config.stripe.api_key
