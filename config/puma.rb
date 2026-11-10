# Puma configuration.
# See: https://puma.io/puma/Puma/DSL.html

max_threads_count = ENV.fetch("RAILS_MAX_THREADS", 5)
min_threads_count = ENV.fetch("RAILS_MIN_THREADS", max_threads_count)
threads min_threads_count, max_threads_count

# Loopback on the host by default: Apache/cloudflared are the sole public entry.
# Inside the Docker public stack, PUMA_BIND_HOST=0.0.0.0 so Docker's published
# port proxy can reach Puma; publishing itself stays host-loopback-only.
bind "tcp://#{ENV.fetch('PUMA_BIND_HOST', '127.0.0.1')}:#{ENV.fetch('PORT', 3001)}"

environment ENV.fetch("RAILS_ENV", "development")

# Only use workers in production.
# macOS fork() safety: cluster mode crashes in dev on Apple Silicon.
# Default 0 (single process): this Mac also hosts the 27B model in RAM.
if ENV.fetch("RAILS_ENV", "development") == "production"
  workers ENV.fetch("WEB_CONCURRENCY", 0).to_i
  preload_app!
end

plugin :tmp_restart
