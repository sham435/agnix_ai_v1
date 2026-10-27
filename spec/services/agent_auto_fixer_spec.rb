# frozen_string_literal: true

# spec/services/agent_auto_fixer_spec.rb
#
# Each example deliberately asserts several things at once: the verdict, that
# the source tree is untouched, and what was recorded. One property per example
# would double the file without doubling the safety.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
#
# AgentAutoFixer writes model output directly onto files under app/. That is the
# whole risk in one sentence, and it already went wrong: a routine run replaced
# the body of app/jobs/agent_stream_job.rb with the model's chain of thought,
# because the reply was used verbatim whenever it contained no ```diff fence and
# `patch` was never given a chance to be checked. Every example below pins one
# gate: prose is refused, a diff aimed at another path is refused, a result that
# does not parse is refused, and none of those may touch the source tree.

require "rails_helper"

RSpec.describe AgentAutoFixer do
  # The fixer only acts on a path it finds in the backtrace under app/, so the
  # specs need a real file there. app/assets is not an autoload root, which keeps
  # a probe file from being read as application code.
  let(:probe_root) { Rails.root.join("app/assets/agent_auto_fixer_spec") }
  let(:target) { probe_root.join("probe.rb") }
  let(:other) { probe_root.join("other.rb") }
  let(:client) { instance_double(Llm::Client) }

  let(:source) do
    <<~RUBY
      class Probe
        def call
          1 + 1
        end
      end
    RUBY
  end

  before do
    FileUtils.mkdir_p(probe_root)
    File.write(target, source)
    File.write(other, "class Other; end\n")
    allow(client).to receive(:chat)
  end

  after { FileUtils.remove_entry(probe_root) if File.directory?(probe_root) }

  # Each attempt writes log/auto_fixes/<issue-id>.md (gitignored). Delete only
  # the files this example created, so the suite leaves no residue while the
  # real audit trail from actual runs stays intact.
  around do |example|
    log_dir = Rails.root.join("log", "auto_fixes").to_s
    before = File.directory?(log_dir) ? Dir.children(log_dir) : []
    example.run
    next unless File.directory?(log_dir)

    (Dir.children(log_dir) - before).each { |name| FileUtils.remove_entry(File.join(log_dir, name)) }
  end

  # A fixer wired to the probe file, with the provider call replaced by a stub.
  def build_fixer(path = target)
    described_class.new(error: RuntimeError.new("boom"), backtrace: [ "#{path}:2:in `call'" ]).tap do |fixer|
      allow(fixer).to receive(:llm_client).and_return(client)
    end
  end

  def model_replies(content)
    allow(client).to receive(:chat).and_return({ content: content })
  end

  # A real unified diff, produced by git itself and re-headed for the repo path
  # the fixer expects (git's --no-index output names the temp files).
  def git_diff(from, to, path)
    a = Tempfile.new([ "from", ".rb" ]); a.write(from); a.close
    b = Tempfile.new([ "to", ".rb" ]); b.write(to); b.close
    out = `git -c core.quotepath=false diff --no-index --no-color #{a.path} #{b.path}`
    a.unlink; b.unlink
    out.sub(%r{^--- .*$}, "--- a/#{path}")
       .sub(%r{^\+\+\+ .*$}, "+++ b/#{path}")
  end

  def repo_path(path)
    path.relative_path_from(Rails.root).to_s
  end

  def last_attempt
    AutoFixAttempt.order(created_at: :desc).first
  end

  # ── refusals: the source tree is never touched ────────────────────────

  it "refuses a reply that is not a diff and leaves the file byte-identical" do
    model_replies("I think the bug is that `1 + 1` is pointless. Let me rewrite the method for you.")
    fixer = build_fixer

    expect(fixer.call).to be false
    expect(File.read(target)).to eq(source)
    expect(last_attempt.status).to eq("FAILED")
  end

  it "refuses a whole-file rewrite delivered in a ```ruby fence" do
    # The old code accepted a ```ruby block and wrote it verbatim. A rewrite is
    # not a minimal diff, and there is no way to tell a good one from prose.
    model_replies("```ruby\n#{source.sub("1 + 1", "2 + 2")}```")
    fixer = build_fixer

    expect(fixer.call).to be false
    expect(File.read(target)).to eq(source)
  end

  it "refuses a diff whose headers patch a file other than the one that raised" do
    model_replies(git_diff("class Other; end\n", "class Other\n  def x = 1\nend\n", repo_path(other)))
    fixer = build_fixer

    expect(fixer.call).to be false
    expect(File.read(other)).to eq("class Other; end\n")
    expect(File.read(target)).to eq(source)
  end

  it "refuses a diff whose result does not parse" do
    # `patch` applies this happily (it knows nothing about Ruby) and the file
    # would have been live in the dev server's autoload path. The syntax gate is
    # the only thing between a plausible-looking diff and a broken app.
    model_replies(git_diff(source, "class Probe\n  def call\n    1 + 1\n", repo_path(target)))
    fixer = build_fixer

    expect(fixer.call).to be false
    expect(File.read(target)).to eq(source)
  end

  it "refuses to patch anything that is not Ruby source" do
    template = probe_root.join("probe.html.erb")
    File.write(template, "<%= 1 + 1 %>\n")
    model_replies(git_diff("<%= 1 + 1 %>\n", "<%= 2 + 2 %>\n", repo_path(template)))
    fixer = build_fixer(template)

    expect(fixer.call).to be false
    expect(File.read(template)).to eq("<%= 1 + 1 %>\n")
  end

  it "does not call the provider at all when the backtrace holds no app file" do
    fixer = described_class.new(error: RuntimeError.new("boom"), backtrace: [ "lib/nothing.rb:1:in `x'" ])

    expect(fixer.call).to be false
    expect(client).not_to have_received(:chat)
  end

  # ── the accepted path ─────────────────────────────────────────────────

  it "applies a genuine minimal diff and reports success" do
    model_replies(git_diff(source, source.sub("1 + 1", "2 + 2"), repo_path(target)))
    fixer = build_fixer

    expect(fixer.call).to be true
    expect(File.read(target)).to eq(source.sub("1 + 1", "2 + 2"))
    expect(last_attempt.status).to eq("SUCCESS")
  end

  it "applies a diff wrapped in prose and fences" do
    diff = git_diff(source, source.sub("1 + 1", "2 + 2"), repo_path(target))
    model_replies("Sure! Here is the fix:\n```diff\n#{diff}\n```\nLet me know if you want tests too.")
    fixer = build_fixer

    expect(fixer.call).to be true
    expect(File.read(target)).to include("2 + 2")
  end

  # ── #slice_diff ───────────────────────────────────────────────────────

  describe "#slice_diff" do
    subject(:sliced) { build_fixer.send(:slice_diff, reply) }

    let(:diff) { git_diff(source, source.sub("1 + 1", "2 + 2"), repo_path(target)) }
    let(:diff_body) { diff.lines[diff.lines.index { |line| line.start_with?("--- a/") }..].join }

    context "with a fenced diff surrounded by prose" do
      let(:reply) { "Here you go:\n```diff\n#{diff}\n```\nHope that helps!" }

      it "returns just the diff, headers to last hunk line" do
        expect(sliced).to eq(diff_body)
      end
    end

    context "with a bare diff and no fences" do
      let(:reply) { "I found the problem.\n#{diff}Review it before applying." }

      it "still returns only the diff" do
        expect(sliced).to eq(diff_body)
      end
    end

    context "with a reply that contains no diff" do
      let(:reply) { "Just rewrite the method with a guard clause and it will work." }

      it "returns nil" do
        expect(sliced).to be_nil
      end
    end

    context "with an empty reply" do
      let(:reply) { "" }

      it "returns nil" do
        expect(sliced).to be_nil
      end
    end
  end
end
