class AgentAutoFixer
  CALLER_PREFIX = Rails.root.join("app").to_s.freeze

  # Line prefixes that may legitimately appear inside a unified diff: file
  # headers, hunk markers, git/index/mode lines and the "\ No newline at end of
  # file" marker. Together with the context/added/removed column markers these
  # are everything a diff body can contain: the first line outside the set ends
  # the diff, so a model's closing commentary can never be handed to `patch` as
  # instructions.
  DIFF_BODY_PREFIXES = [
    "--- a/", "--- b/", "+++ a/", "+++ b/", "@@", "diff --git", "index ",
    "new file", "deleted file", "old file", "new mode", "rename ", "similarity "
  ].freeze

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

    raw = fetch_patch(context)
    return false unless raw

    patch = slice_diff(raw)
    refusal = patch ? validate(patch, app_file) : "reply contained no unified diff"
    if refusal
      # Refusing is the whole point of this branch: the source tree is not
      # touched, and the reason is recorded for review.
      Rails.logger.error "[AgentAutoFixer] REFUSED #{log[:file]}: #{refusal}"
      write_attempt(1, patch || raw, false, log)
      return false
    end

    backup = File.read(app_file)
    ok, err = apply_patch(app_file, patch)
    write_attempt(1, patch, ok, log)
    return true if ok

    # apply_patch only swaps in content that already parsed, so this normally
    # rewrites an untouched file. It exists for the case it cannot see: a patch
    # tool that wrote something and still reported failure.
    restore_if_changed(app_file, backup)
    Rails.logger.error "[AgentAutoFixer] ROLLBACK #{log[:file]}: #{err}"
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
      Rails.root.join("spec", rel.sub(/\.rb\z/, "s_spec.rb"))
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
      If a minimal diff is not possible, reply with exactly NO PATCH and nothing else.

      ERROR:
      #{context[:error]}

      CURRENT FILE:
      #{context[:code]}

      RECENT GIT DIFF:
      #{context[:diff]}
    PROMPT

    result = llm_client.chat(messages: [ { role: "user", content: prompt } ])
    result[:content].to_s.presence
  rescue StandardError => e
    # The auto-fixer is best-effort: any LLM failure (network, auth, provider
    # limits like a 403 free-tier rejection) stops this fix attempt instead of
    # crashing whoever triggered the original error handling.
    Rails.logger.error "[AgentAutoFixer] LLM failed: #{e.class}: #{e.message.truncate(200)}"
    nil
  end

  # Lift the unified diff out of whatever else the model typed. The reply used to
  # fall through to the raw content when no ```diff fence was present, and that
  # content was then written over the source file — which is how a chain of
  # thought became the body of app/jobs/agent_stream_job.rb.
  #
  # Leading prose is skipped by anchoring on the first `--- a/` header, and
  # trailing prose is cut off at the first line that cannot belong to a diff
  # body, so `patch` never receives commentary as instructions.
  def slice_diff(text)
    body = text.to_s
    body = body[/```(?:diff|patch)[ \t]*\n(.*?)\n```/m, 1] || body
    lines = body.lines
    start = lines.index { |line| line.start_with?("--- a/") }
    return nil unless start

    taken = []
    lines[start..].each do |line|
      break unless diff_body_line?(line)

      taken << line
    end
    diff = taken.join
    diff.include?("@@") ? diff : nil
  end

  # Context lines, additions, deletions, the "\ No newline" marker and the
  # git/patch header lines are the entire legal vocabulary of a diff body.
  def diff_body_line?(line)
    return true if line.start_with?(" ", "+", "-", "\\")

    DIFF_BODY_PREFIXES.any? { |prefix| line.start_with?(prefix) }
  end

  # A diff is only usable when its shape is a unified diff, it patches Ruby
  # source, and its `+++ b/` header names the file that actually raised. Each
  # condition was missing before: the fixer wrote whatever the model typed onto
  # whatever path the diff happened to name.
  #
  # Returns nil when the patch is accepted, otherwise the refusal reason.
  def validate(patch, file_path)
    return "only .rb sources are patched (got #{File.extname(file_path.to_s).presence || "no extension"})" unless File.extname(file_path.to_s) == ".rb"
    return "reply is not a unified diff" unless patch.match?(/\A--- a\/[^\n]+\n\+\+\+ b\/[^\n]+\n@@/m)

    target = diff_target(patch)
    return "diff headers could not be parsed" unless target
    return "diff targets #{target}, not #{relative_path(file_path)}" unless same_path?(target, file_path)

    nil
  end

  # The path a patch claims to write, with the `b/` prefix and any trailing
  # tab-separated timestamp removed. /dev/null (a deletion) is not a target.
  def diff_target(patch)
    header = patch.lines.find { |line| line.start_with?("+++ ") }
    return nil unless header

    path = header[4..].to_s.split("\t").first.to_s.strip
    path = path.sub(%r{\Ab/}, "")
    path.presence unless path.empty? || path == "/dev/null"
  end

  # Diff headers are repo-relative (`a/app/...`), the backtrace gives absolute
  # paths, and models emit both. Compare resolved, so `../` tricks cannot point
  # the fixer at a file outside the one that failed.
  def same_path?(candidate, file_path)
    File.expand_path(candidate.to_s, Rails.root).to_s == File.expand_path(file_path.to_s).to_s
  end

  def relative_path(file_path)
    Pathname.new(file_path.to_s).relative_path_from(Rails.root).to_s
  rescue ArgumentError
    file_path.to_s
  end

  # `patch` runs against a scratch copy and the copy is syntax-checked before a
  # single byte reaches the source tree. The old code wrote straight over the
  # live file, so a bad patch was immediately in the editor, in git's worktree
  # and in the dev server's autoload path — with nothing to roll back to.
  def apply_patch(file_path, diff)
    work = Tempfile.new([ File.basename(file_path.to_s, ".*"), ".rb" ])
    work.write(File.read(file_path))
    work.close

    patch_file = Tempfile.new([ "autofix", ".diff" ])
    patch_file.write(diff)
    patch_file.close

    _stdout, stderr, status = Open3.capture3("patch", work.path, patch_file.path)
    return [ false, "patch failed: #{stderr.to_s.strip.presence || "non-zero exit"}" ] unless status.success?

    patched = File.read(work.path)
    return [ false, "patch produced an empty file" ] if patched.strip.empty?

    syntax = syntax_error(work.path)
    return [ false, "patched source does not parse: #{syntax}" ] if syntax

    File.write(file_path, patched)
    [ true, "" ]
  ensure
    [ work, patch_file ].each do |tmp|
      next unless tmp

      begin
        tmp.unlink
      rescue StandardError => e
        Rails.logger.warn "[AgentAutoFixer] temp file cleanup failed: #{e.class}: #{e.message}"
      end
    end
  end

  # Restore the pre-patch content, but only when it actually differs — rewriting
  # an untouched file would churn mtimes and force an app reload for nothing.
  def restore_if_changed(file_path, backup)
    File.write(file_path, backup) if File.read(file_path) != backup
  rescue StandardError => e
    Rails.logger.error "[AgentAutoFixer] RESTORE-FAILED #{file_path}: #{e.class}: #{e.message}"
  end

  # The one check that catches the class of damage this fixer used to do: text
  # that looks like output but is not valid Ruby (prose, or a diff with its own
  # headers left in). `nil` means the file parses.
  def syntax_error(path)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", path)
    return nil if status.success?

    stderr.to_s.strip.truncate(300).presence || "syntax error"
  rescue StandardError => e
    "#{e.class}: #{e.message}"
  end

  def write_attempt(iteration, patch, success, log_data)
    AutoFixAttempt.create!(
      issue_id: @issue_id,
      iteration: iteration,
      status: success ? "SUCCESS" : "FAILED",
      stderr: @error.to_s.truncate(10_000),
      patch: patch.to_s.truncate(10_000),
      files_modified: [ log_data[:file] ],
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
    @llm_client ||= begin
      agent = @conversation&.agent
      if agent&.model.present?
        # Prefer the conversation's own agent model: it is configured for this
        # project, points at the local Bonsai/Ollama servers in most runs, and
        # needs no external network or paid API keys.
        Llm::Client.new(provider: agent.provider, model: agent.model, api_key: agent.try(:api_key))
      else
        Llm::Client.new(provider: "opencode", model: "big-pickle", api_key: ENV.fetch("OPENCODE_API_KEY", ""))
      end
    end
  end
end
