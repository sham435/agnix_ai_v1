# Puma configuration.
# See: https://puma.io/puma/Puma/DSL.html

max_threads_count = ENV.fetch("RAILS_MAX_THREADS", 5)
min_threads_count = ENV.fetch("RAILS_MIN_THREADS", max_threads_count)
threads min_threads_count, max_threads_count

port ENV.fetch("PORT", 3001)

environment ENV.fetch("RAILS_ENV", "development")

# Only use workers in production.
# macOS fork() safety: cluster mode crashes in dev on Apple Silicon.
if Rails.env.production?
  workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
  preload_app!
end

plugin :tmp_restart
