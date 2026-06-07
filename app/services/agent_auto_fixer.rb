class AgentAutoFixer
  CALLER_PREFIX = Rails.root.join("app").to_s.freeze

  def initialize(error:, backtrace:, conversation: nil)
    @error = error
    @backtrace = backtrace || []
    @conversation = conversation
    @issue_id = "agent-#{SecureRandom.hex(8)}"
  end

  def call
    app_file = find_app_file
    return log_orphan_error unless app_file

    spec = find_spec(app_file)
    context = build_context(app_file)
    log = build_log(app_file, spec)

    patch = fetch_patch(context)
    return false unless patch

    backup = File.read(app_file)
    ok, err = apply_patch(app_file, patch)
    write_attempt(1, patch, ok, log)
    return true if ok

    File.write(app_file, backup)
    false
  end

  private

  def find_app_file
    @backtrace.each do |line|
      next unless line.start_with?(CALLER_PREFIX)
      normalized = line.split(":")[0..-3].join(":")  # strip line number
      path = line.split(":")[0]
      return path if File.exist?(path)
    end
    nil
  end

  def find_spec(app_file)
    rel = Pathname.new(app_file).relative_path_from(Rails.root.join("app")).to_s
    candidates = [
      Rails.root.join("spec", rel.sub(/\.rb\z/, "_spec.rb")),
      Rails.root.join("spec", rel.sub(/\.rb\z/, "s_spec.rb")),
    ]
    candidates.find(&:exist?)&.to_s
  end

  def build_context(app_file)
    diff_stdout, _stderr, _status = Open3.capture3("git", "diff", "HEAD~1", "--", app_file.to_s)
    {
      error: @error,
      code: File.read(app_file),
      diff: diff_stdout,
      backtrace: @backtrace.first(15).join("\n")
    }
  end

  def fetch_patch(context)
    prompt = <<~PROMPT
      You are an automated Rails fix agent.
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

  def apply_patch(file_path, diff)
    return [false, "No diff content"] if diff.blank?

    patched = diff.dup
    patched.gsub!(/^```diff\n/, "")
    patched.gsub!(/^```ruby\n/, "")
    patched.gsub!(/^```\n?/, "")

    if patched.match?(/\A--- a\/.*\n\+\+\+ b\/.*/m)
      tmp = Tempfile.new(["patch", ".diff"])
      tmp.write(patched)
      tmp.close
      _stdout, stderr, status = Open3.capture3("patch", file_path.to_s, tmp.path)
      tmp.unlink
      [status.success?, stderr.to_s.strip]
    else
      File.write(file_path, patched)
      [true, ""]
    end
  end

  def write_attempt(iteration, patch, success, log_data)
    AutoFixAttempt.create!(
      issue_id: @issue_id,
      iteration: iteration,
      status: success ? "SUCCESS" : "FAILED",
      stderr: @error.to_s.truncate(10_000),
      patch: patch,
      files_modified: [log_data[:file]],
      duration_ms: 0
    )

    FileUtils.mkdir_p(File.dirname(log_data[:log_path]))
    File.open(log_data[:log_path], "a") do |f|
      f.puts "### AutoFix #{@issue_id} - #{Time.current.iso8601}"
      f.puts "**Status:** #{success ? 'SUCCESS' : 'FAILED'}"
      f.puts "**File:** #{log_data[:file]}"
      f.puts "**Spec:** #{log_data[:spec]}"
      f.puts "**Error:** #{@error}"
      f.puts "```diff\n#{patch}\n```"
      f.puts
    end
  end

  def build_log(app_file, spec)
    {
      file: app_file,
      spec: spec,
      log_path: Rails.root.join("log", "auto_fixes", "#{@issue_id}.md")
    }
  end

  def log_orphan_error
    Rails.logger.warn "[AgentAutoFixer] No app file found in backtrace for: #{@error.message.truncate(120)}"
    false
  end

  def llm_client
    @llm_client ||= Llm::Client.new(
      provider: "opencode",
      model: "big-pickle",
      api_key: ENV.fetch("OPENCODE_API_KEY", "")
    )
  end
end
