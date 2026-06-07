source "https://rubygems.org"

# -- Ruby --
ruby "~> 3.4.0"

# -- Rails 8.1 --
gem "rails", "~> 8.1.3"

# -- Database --
gem "pg", "~> 1.5"
gem "pgvector", "~> 0.2"           # Vector similarity search for RAG
gem "redis", "~> 5.0"              # Redis client for cache/pubsub

# -- Web server --
gem "puma", "~> 7.0", ">= 7.0.4"   # Production app server
gem "bootsnap", "~> 1.18"          # Boot speed optimization

# -- Rails Solid gems (no external infra needed) --
gem "solid_queue", "~> 1.1"        # Persistent background job queue
gem "solid_cache", "~> 1.0"        # Persistent cache store
gem "solid_cable", "~> 4.0"        # Action Cable PostgreSQL backend

# -- Assets & Frontend --
gem "tailwindcss-rails", "~> 4.0"
gem "propshaft"                    # Asset pipeline
gem "rack-cors", "~> 2.0"          # CORS middleware
gem "importmap-rails", "~> 2.0"    # ES module imports
gem "turbo-rails", "~> 2.0"        # Hotwire Turbo
gem "stimulus-rails", "~> 1.3"     # Stimulus JS framework
gem "jbuilder", "~> 2.11"          # JSON API views

# -- Markdown & Rendering --
gem "rouge"                        # Syntax highlighting
gem "commonmarker", "~> 2.0"       # GitHub-flavored markdown

# -- ViewComponents --
gem "view_component", "~> 3.21"
gem "phlex-rails", "~> 2.2"

# -- Auth & Security --
gem "bcrypt", "~> 3.1"             # Password hashing
gem "omniauth", "~> 2.1"           # OAuth framework
gem "omniauth-rails_csrf_protection", "~> 1.0"
gem "omniauth-google-oauth2", "~> 1.2"
gem "omniauth-github", "~> 2.0"

# -- HTTP & APIs --
gem "httparty", "~> 0.22"          # HTTP client for LLM integrations
gem "faraday", "~> 2.12"           # HTTP for webhooks
gem "json_schemer", "~> 2.5"        # JSON Schema validation for tool calling

# -- Email --
gem "postmark-rails", "~> 0.22"    # Transactional email

# -- Integrations --
gem "stripe", "~> 13.0"            # Stripe API
# WhatsApp Cloud API via HTTParty (see app/services/whatsapp_service.rb)

# -- Storage --
gem "aws-sdk-s3", "~> 1.170", require: false  # Active Storage S3
gem "image_processing", "~> 1.14"             # Image variants

# -- Background --
# Solid Queue periodic jobs replace solid_cron (Rails 8.1 built-in)

# -- Monitoring & Observability --
gem "sentry-rails", "~> 5.22"
gem "sentry-ruby", "~> 5.22"

# -- Pagination & Filtering --
gem "pagy", "~> 9.0"               # Lightweight pagination

# -- Search --
gem "ransack", "~> 4.2"            # Search forms

group :development, :test do
  gem "debug", platforms: %i[mri windows]
  gem "rspec-rails", "~> 7.0"
  gem "factory_bot_rails", "~> 6.4"
  gem "faker", "~> 3.5"
  gem "webmock", "~> 3.25"
  gem "database_cleaner-active_record", "~> 2.1"
  gem "simplecov", "~> 0.22", require: false
  gem "shoulda-matchers", "~> 6.4"
  gem "rails-controller-testing", "~> 1.0"
  gem "timecop", "~> 0.9"
end

group :development do
  gem "brakeman", "~> 7.0"
  gem "bundler-audit", "~> 0.9"
  gem "rubocop-rails-omakase", "~> 1.0", require: false
  gem "rubocop-rspec", "~> 3.4", require: false
  # annotate not yet compatible with Rails 8.1
  gem "letter_opener", "~> 1.10"
  gem "web-console", "~> 4.2"
  gem "bullet", "~> 8.0"
end

group :test do
  gem "capybara", "~> 3.40"
  gem "selenium-webdriver", "~> 4.27"
end

gem "cuprite", "~> 0.17", group: :test
