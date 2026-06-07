require "open3"
require "fileutils"

module AiCopilot
  class AutoFixService
    MAX_RETRIES = 5
    ALLOWLIST = %r{\Aapp/(models|services|controllers|components)/.*\.rb\z}

    def initialize(issue_id:, file_path:, spec_path:, conversation: nil)
      @issue_id = issue_id
      @file_path = Rails.root.join(file_path)
      @spec_path = Rails.root.join(spec_path)
      @conversation = conversation
      @log_path = Rails.root.join("log", "auto_fixes", "fix-#{issue_id}.md")
      FileUtils.mkdir_p(File.dirname(@log_path))
    end

    def call
      passed, output = run_spec
      return true if passed

      iteration = 0
      current_error = output
      baseline_failures = failure_count(output)
      @baseline_error = output

      while iteration < MAX_RETRIES
        iteration += 1
        broadcast "Analyzing error and generating minimal patch (#{iteration}/#{MAX_RETRIES})…"

        context = build_context(current_error)
        patch = fetch_minimal_patch(context)
        return false if patch.blank?

        backup = File.read(@file_path)
        patch_applied, patch_err = apply_patch(patch)

        unless patch_applied
          broadcast "⚠ Patch application failed: #{patch_err}"
          File.write(@file_path, backup)
          current_error = output
          next
        end

        passed, output = run_spec
        write_telemetry(iteration, patch, passed, output)

        if passed
          broadcast "✓ Fix applied. Spec passed."
          return true
        elsif worse_errors?(output, baseline_failures, iteration)
          rollback_ok, rollback_err = git_rollback!
          if rollback_ok
            broadcast "⟳ Patch introduced regressions — rolled back to HEAD. Retry #{iteration}/#{MAX_RETRIES}…"
          else
            broadcast "⟳ Git rollback failed (#{rollback_err}), restoring file backup. Retry #{iteration}/#{MAX_RETRIES}…"
            File.write(@file_path, backup)
          end
          current_error = output
        else
          File.write(@file_path, backup)
          current_error = output
          broadcast "Retry #{iteration}/#{MAX_RETRIES}…"
        end
      end

      broadcast "✗ Fix loop exceeded #{MAX_RETRIES} retries"
      false
    end

    private

    def run_spec
      cmd = if @spec_path.to_s.end_with?("_spec.rb")
              %w[bundle exec rspec --require support/auto_fix_stubs --format progress]
            else
              %w[bundle exec rails test]
            end
      stdout, stderr, status = Open3.capture3(*cmd, @spec_path.to_s)
      @last_stderr = combine_output(stdout, stderr)
      [status.success?, @last_stderr]
    end

    def combine_output(stdout, stderr)
      out = stdout.to_s.strip
      err = stderr.to_s.strip
      [out, err].reject(&:empty?).join("\n")
    end

    def last_stderr
      @last_stderr || ""
    end

    def failure_count(output)
      output.scan(/Failure\/Error:/).size
    end

    def error_signatures(output)
      output.scan(/(?:\b|\n)((?:[A-Z]\w*::)*[A-Z]\w*(?:Error|Exception|NotFound|Invalid|NotUnique|NotSaved|NotDestroyed|Missing|Conflict|Forbidden|Timeout))\b/).flatten.uniq.sort
    end

    def worse_errors?(output, baseline_failures, iteration)
      return false if iteration == 1

      current_failures = failure_count(output)
      current_sigs = error_signatures(output)
      baseline_sigs = error_signatures(@baseline_error.to_s)

      new_errors = current_sigs - baseline_sigs
      more_failures = current_failures > baseline_failures

      more_failures || new_errors.any?
    end

    def build_context(error)
      diff_stdout, diff_stderr, diff_status = Open3.capture3(
        "git", "diff", "HEAD~1", "--", @file_path.to_s
      )

      {
        error: error,
        code: File.read(@file_path),
        diff: diff_status.success? ? diff_stdout : "Git diff failed: #{diff_stderr.strip}",
        backtrace: caller[0..20].join("\n")
      }
    end

    def fetch_minimal_patch(context)
      prompt = <<~PROMPT
        You are an automated Rails refactoring agent.
        Fix the error below with a MINIMAL unified diff. Do not rewrite the whole file.
        Return ONLY the diff in ```diff ... ``` blocks.

        ERROR:
        #{context[:error]}

        CURRENT FILE:
        #{context[:code]}

        RECENT GIT DIFF:
        #{context[:diff]}
      PROMPT

      result = llm_client.chat(messages: [{ role: "user", content: prompt }])
      content = result[:content].to_s
      content[/```diff\n(.*?)\n```/m, 1] || content[/```ruby\n(.*?)\n```/m, 1] || content
    end

    def llm_client
      @llm_client ||= Llm::Client.new(
        provider: "opencode",
        model: "big-pickle",
        api_key: ENV["OPENCODE_API_KEY"] || ""
      )
    end

    def apply_patch(diff)
      return [false, "No diff content"] if diff.blank?

      patched = diff.dup
      patched.gsub!(/^```diff\n/, "")
      patched.gsub!(/^```ruby\n/, "")
      patched.gsub!(/^```\n?/, "")

      if patched.match?(/\A--- a\/.*\n\+\+\+ b\/.*/m)
        tmp = Tempfile.new(["patch", ".diff"])
        tmp.write(patched)
        tmp.close
        _stdout, stderr, status = Open3.capture3("patch", @file_path.to_s, tmp.path)
        tmp.unlink
        [status.success?, stderr.to_s.strip]
      else
        File.write(@file_path, patched)
        [true, ""]
      end
    end

    def git_rollback!
      _stdout, stderr, status = Open3.capture3(
        "git", "checkout", "--", @file_path.to_s
      )

      if status.success?
        @rolled_back = true
        [true, ""]
      else
        [false, stderr.to_s.strip]
      end
    end

    def write_telemetry(iteration, diff, passed, output)
      AutoFixAttempt.create!(
        issue_id: @issue_id,
        iteration: iteration,
        status: passed ? "SUCCESS" : "FAILED",
        stderr: output.truncate(10_000),
        patch: diff,
        files_modified: [@file_path.to_s],
        duration_ms: 0
      )

      File.open(@log_path, "a") do |f|
        f.puts "### Attempt #{iteration} - #{Time.current.iso8601}"
        f.puts "**Status:** #{passed ? 'SUCCESS' : 'FAILED'}"
        f.puts "**Rolled back:** #{@rolled_back ? 'Yes' : 'No'}"
        f.puts "```diff\n#{diff}\n```"
        f.puts "```text\n#{output.truncate(10_000)}\n```"
        f.puts
      end
    end

    def broadcast(text)
      return unless @conversation

      Turbo::StreamsChannel.broadcast_append_to(
        @conversation,
        target: "messages-list",
        partial: "ai_copilot/status",
        locals: { text: text }
      )
    end
  end
end
