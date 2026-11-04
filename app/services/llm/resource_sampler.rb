# frozen_string_literal: true

module Llm
  # Observability for local-model turns, so a "busy box" can be told apart from
  # a "slow model" after the fact.
  #
  # Records the three host facts that matter when a long generation EOFs on the
  # single-slot llama server: swap usage, the macOS memory-pressure level, and
  # the resident set size of the running llama-server. It is read once per
  # provider call and logged next to the existing [LLM] latency line.
  #
  # It never raises: sampling is a nicety, and a failed read must not fail a
  # run. On non-macOS hosts (where these sysctl/ps interfaces differ) it simply
  # returns an empty sample.
  class ResourceSampler
    SWAP_CMD = "sysctl -n vm.swapusage"
    PRESSURE_CMD = "memory_pressure"
    RSS_CMD = "ps -axo rss=,command= | grep -i '[l]lama-server'"

    LOCAL_PROVIDERS = %w[bonsai ollama].freeze

    def self.local?(provider)
      LOCAL_PROVIDERS.include?(provider.to_s)
    end

    # Best-effort host snapshot. Returns {} when the provider is not local, the
    # platform is unsupported, or any read fails, so callers can log
    # unconditionally and never risk failing a run on a diagnostic.
    def self.sample(provider:, model:)
      return {} unless local?(provider)
      return {} unless RbConfig::CONFIG["host_os"].to_s.match?(/darwin/i)

      new.host_sample
    rescue StandardError => e
      Rails.logger.warn "[ResourceSampler] #{e.class}: #{e.message}"
      {}
    end

    def host_sample
      {
        swap_used_mb: swap_used_mb,
        memory_free_pct: memory_free_pct,
        llama_rss_mb: llama_rss_mb
      }.compact
    end

    private

    # vm.swapusage -> "total = 8192.00M  used = 7102.69M  free = 1089.31M"
    def swap_used_mb
      out = read(SWAP_CMD)
      m = out && out[/used = ([\d.]+)M/, 1]
      m && m.to_f.round(1)
    end

    # memory_pressure -> "... System-wide memory free percentage: 41%"
    def memory_free_pct
      out = read(PRESSURE_CMD)
      m = out && out[/free percentage:\s*([\d.]+)%/, 1]
      m && m.to_f.round(1)
    end

    # Sum RSS (KB -> MB) of every llama-server process (bonsai + ollama).
    def llama_rss_mb
      out = read(RSS_CMD)
      return nil if out.nil? || out.strip.empty?

      total_kb = out.each_line.sum { |line| line[/^\s*(\d+)/, 1].to_i }
      (total_kb / 1024.0).round(1)
    end

    # Fixed command strings, no interpolation -> a safe, read-only shell probe.
    # A non-zero exit or a missing binary yields nil, never an exception.
    def read(cmd)
      IO.popen(cmd) { |io| io.read }
    rescue StandardError
      nil
    end
  end
end
