# frozen_string_literal: true

require "fileutils"

module Agents
  # Executes OS-level actions (shell commands, Python/Ruby code, file
  # reads/writes) for agent OS modes (Auto Plan / Auto Build / resumptions).
  #
  # Guardrails:
  #   * Only absolute paths under ALLOWED_ROOTS are touched; the deepest
  #     existing ancestor is realpath-resolved before permission checks, so
  #     symlink tricks are rejected.
  #   * The host Rails app's own code tree is off-limits: the agent can never
  #     modify the product that is running it.
  #   * Catastrophic shell patterns are rejected before spawn.
  #   * Every execution runs under a hard timeout (default 30s, max 120s).
  #   * Captured output is capped so tool results stay context-friendly.
  class OsExecutor
    OUTPUT_LIMIT = 8_000
    DEFAULT_TIMEOUT = 30
    MAX_TIMEOUT = 120
    MAX_READ_BYTES = 1_000_000

    DANGEROUS_PATTERNS = [
      /\bsudo\b/,
      /\bsu\s+-?\w/,
      /\bshutdown\b/,
      /\breboot\b/,
      /\bmkfs\b/,
      /\bdiskutil\b/,
      /\bkillall\b/,
      /\bkill\s+-9\s+1\b/,
      /\brm\s+-[a-z]*[fr][a-z]*\s+\/[\s"';]/, # rm with flags against filesystem root
      /\b:\(\)\s*\{.*\}\s*;\s*:/,             # fork bomb
      /\bcurl\b[^|]*\|\s*(ba)?sh\b/,
      /\bwget\b[^|]*\|\s*(ba)?sh\b/,
      /\bdocker\s+system\s+prune\b/
    ].freeze

    class << self
      def run_command(command, workdir: nil, timeout: DEFAULT_TIMEOUT)
        command = command.to_s
        raise SecurityError, "Empty command" if command.strip.empty?
        guard_command!(command)
        dir = allow_directory!(workdir)

        stdout, stderr, exit_code, timed_out = capture(%W[bash -lc #{command}], dir, timeout)
        if timed_out
          { ok: false, error: "Timed out after #{timeout}s",
            stdout: clip(stdout), stderr: clip(stderr) }
        else
          { ok: exit_code.zero?, exit_code: exit_code,
            stdout: clip(stdout), stderr: clip(stderr) }
        end
      end

      def run_code(code, language: "python", workdir: nil, timeout: DEFAULT_TIMEOUT)
        argv = case language.to_s
        when /\Apy/ then %W[python3 -c #{code}]
        when /\A(ruby|rb)/ then %W[ruby -e #{code}]
        else
          return { ok: false, error: "Unsupported language: #{language}" }
        end
        dir = allow_directory!(workdir)

        stdout, stderr, exit_code, timed_out = capture(argv, dir, timeout)
        if timed_out
          { ok: false, error: "Timed out after #{timeout}s",
            stdout: clip(stdout), stderr: clip(stderr) }
        else
          { ok: exit_code.zero?, exit_code: exit_code,
            stdout: clip(stdout), stderr: clip(stderr) }
        end
      end

      def write_file(path, content)
        abs = expand_path_safely!(path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, content.to_s)
        { ok: true, path: abs, bytes: content.to_s.bytesize }
      end

      def read_file(path)
        abs = expand_path_safely!(path)
        raise SecurityError, "File not found: #{abs}" unless File.file?(abs)

        content = File.read(abs, MAX_READ_BYTES)
        { ok: true, path: abs, content: clip(content),
          truncated: content.bytesize >= MAX_READ_BYTES }
      end

      private

      # Roots where the agent may create/execute files. Override with a
      # semicolon-separated list via SHAMS_OS_ALLOWED_ROOTS.
      def allowed_roots
        @allowed_roots ||= begin
          from_env = ENV["SHAMS_OS_ALLOWED_ROOTS"].to_s.split(";").map(&:strip).reject(&:empty?)
          (from_env.presence || %w[/Users /tmp /private/tmp]).freeze
        end
      end

      def in_allowed_roots?(real_path)
        app_root = Rails.root.to_s
        return false if real_path == app_root || real_path.start_with?(app_root + "/")

        allowed_roots.any? do |root|
          base = begin
            File.realpath(root)
          rescue StandardError
            root
          end
          real_path == base || real_path.start_with?(base + "/")
        end
      end

      # Walk up to the deepest existing ancestor, realpath it and make sure it
      # is inside the allowed roots (this also defeats symlink escapes).
      def expand_path_safely!(path)
        abs = File.expand_path(path.to_s)
        raise SecurityError, "Path must be absolute: #{path}" unless abs.start_with?("/")

        existing = abs
        existing = File.dirname(existing) while existing != "/" && !File.exist?(existing)
        real = File.realpath(existing)
        raise SecurityError, "Blocked path (outside allowed roots): #{path}" unless in_allowed_roots?(real)

        abs
      end

      def allow_directory!(workdir)
        # Default to the user's home: the Rails process cwd (the app repo) is
        # off-limits, so it must never be the fallback workspace.
        workdir = workdir.presence || ENV["HOME"].presence || "/tmp"
        abs = File.expand_path(workdir.to_s)
        raise SecurityError, "Workdir not found: #{workdir}" unless File.directory?(abs)

        real = File.realpath(abs)
        raise SecurityError, "Blocked workdir: #{workdir}" unless in_allowed_roots?(real)
        abs
      end

      def guard_command!(command)
        hit = DANGEROUS_PATTERNS.find { |re| re.match?(command) }
        return unless hit

        raise SecurityError, "Blocked by safety guardrail: pattern #{hit.source[0, 48]}"
      end

      # Hard-timeout process capture: spawns the argv, streams stdout/stderr
      # with a select loop until EOF or the deadline, then reaps the process
      # group so nothing survives the timeout.
      def capture(argv, workdir, timeout)
        timeout = [ [ timeout.to_i, 1 ].max, MAX_TIMEOUT ].min
        stdout = +""
        stderr = +""
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(*argv, chdir: workdir, out: out_w, err: err_w, pgroup: true)
        out_w.close
        err_w.close

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        open_ios = [ out_r, err_r ]
        timed_out = false

        until open_ios.empty?
          break if deadline <= Process.clock_gettime(Process::CLOCK_MONOTONIC)

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ready = IO.select(open_ios, nil, nil, remaining)
          break if ready.nil? && deadline <= Process.clock_gettime(Process::CLOCK_MONOTONIC)

          if ready
            ready[0].each do |io|
              chunk = io.read_nonblock(64_000, exception: false)
              next unless chunk.is_a?(String)

              (io == out_r ? stdout : stderr) << chunk
            end
          end

          open_ios.select! { |io| !io.eof? }
        end

        if deadline <= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          timed_out = true
          begin
            Process.kill("KILL", -pid)
          rescue StandardError
            nil
          end
        end

        _waited, status = Process.waitpid2(pid)
        [ stdout, stderr, (status&.exitstatus || 143), timed_out ]
      ensure
        [ out_r, err_r ].each { |io| io.close unless io.closed? }
        nil
      end

      def clip(text)
        text.to_s[0, OUTPUT_LIMIT]
      end
    end
  end
end
