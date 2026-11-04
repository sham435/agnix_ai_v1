# frozen_string_literal: true

module Llm
  # Serializes generations against the single-slot local model servers (Bonsai,
  # Ollama).
  #
  # The llama.cpp server that backs the bonsai/ollama providers runs ONE slot by
  # default (no -np flag -> n_parallel = 1). But the app can fire several agent
  # jobs at once: the dev :async adapter runs jobs on threads inside the web
  # process, and Solid Queue runs with threads: 3. Concurrent requests to a
  # single slot queue server-side until the adapter's READ_TIMEOUT (600s) trips,
  # which surfaces to the user as a mid-stream EOF on exactly the long,
  # multi-file turns that matter most.
  #
  # This gate lets at most LOCAL_MODEL_SLOTS (default 1) generations talk to a
  # local server at a time; everyone else waits its turn instead of colliding.
  # Cloud providers (anthropic/openai/openrouter/google/...) never touch it, so
  # their parallelism is unchanged.
  #
  # Scope is PROCESS-local, which fully serializes the common deployment (one
  # Solid Queue worker process; dev jobs on threads in the web process). A
  # multi-process local deployment would need a shared lock (a DB advisory lock)
  # to coordinate across processes - but holding a DB connection for a
  # five-minute generation is not worth it, so that is documented rather than
  # done.
  class LocalModelGate
    LOCAL_PROVIDERS = %w[bonsai ollama].freeze

    # Raised when a run waits longer than the budget for a free slot. The agent
    # loop already treats a provider error honestly (failed, not completed), so
    # this lands on that path rather than hanging the worker forever behind a
    # wedged predecessor.
    class SlotTimeout < StandardError; end

    class << self
      def instance
        @instance ||= new
      end

      # Test seam: drop the process-wide gate so specs do not leak thread state.
      def reset!
        @instance = nil
      end

      def local?(provider)
        LOCAL_PROVIDERS.include?(provider.to_s)
      end
    end

    def initialize(slots: ENV.fetch("LOCAL_MODEL_SLOTS", 1).to_i,
                   wait_timeout: ENV.fetch("LOCAL_MODEL_WAIT", 900).to_i)
      @slots = [slots, 1].max
      @wait_timeout = wait_timeout
      @mutex = Mutex.new
      @free = ConditionVariable.new
      @in_use = 0
    end

    # Acquire a slot, yield, then always release. Waits up to wait_timeout for
    # capacity so a wedged generation cannot block the queue indefinitely.
    def acquire
      deadline = monotonic + @wait_timeout
      @mutex.synchronize do
        while @in_use >= @slots
          remaining = deadline - monotonic
          raise SlotTimeout, "No local-model slot freed within #{@wait_timeout}s" if remaining <= 0

          @free.wait(@mutex, remaining)
        end
        @in_use += 1
      end

      begin
        yield
      ensure
        @mutex.synchronize do
          @in_use -= 1
          @free.signal
        end
      end
    end

    # Exposed for specs and ops dashboards.
    def in_use
      @mutex.synchronize { @in_use }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
