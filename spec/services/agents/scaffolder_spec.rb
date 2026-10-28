# frozen_string_literal: true

# Narrative scaffolder specs: several assertions per example by design.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/AnyInstance, RSpec/MultipleMemoizedHelpers

require "rails_helper"
require "fileutils"

RSpec.describe Agents::Scaffolder do
  def workspace(name)
    dir = File.join("/tmp", "shams-scaffolder-#{name}-#{SecureRandom.hex(6)}")
    FileUtils.mkdir_p(dir)
    dir
  end

  def remove(dir)
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # Dispatch on the command text so the same stub answers both the interpreter
  # probe (contains "-c") and the "manage.py check" verification.
  def stub_shell(django: true, check_ok: true, executable: "/usr/bin/python3", version: "4.2.30")
    allow(Agents::OsExecutor).to receive(:run_command) do |cmd, **_kw|
      if cmd.include?("-c")
        if django
          { ok: true, exit_code: 0, stdout: "#{version}\n#{executable}", stderr: "" }
        else
          { ok: false, exit_code: 1, stdout: "", stderr: "ModuleNotFoundError: No module named 'django'" }
        end
      elsif cmd.include?("manage.py check")
        if check_ok
          { ok: true, exit_code: 0, stdout: "System check identified no issues (0 silenced).", stderr: "" }
        else
          { ok: false, exit_code: 1, stdout: "", stderr: "ImproperlyConfigured: kaboom" }
        end
      else
        { ok: true, exit_code: 0, stdout: "", stderr: "" }
      end
    end
  end

  def stub_write
    allow(Agents::OsExecutor).to receive(:write_file) do |path, content|
      { ok: true, path: path, bytes: content.to_s.bytesize }
    end
  end

  describe ".scaffold template selection" do
    it "refuses an unknown template without touching the disk" do
      expect(Agents::OsExecutor).not_to receive(:write_file)
      result = described_class.scaffold(template: "rails-api", target_dir: "/tmp/whatever")

      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("unknown_template")
      expect(result[:allowed]).to include("django_landing")
    end
  end

  describe ".scaffold safety" do
    it "surfaces a blocked path as a bounded refusal" do
      allow(Agents::OsExecutor).to receive(:write_file)
        .and_raise(SecurityError, "Blocked path (outside allowed roots): /etc/x")

      result = described_class.scaffold(template: "django_landing", target_dir: "/etc/nope")
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("blocked_path")
      expect(result[:error]).to include('Blocked path')
    end

    it "refuses to clobber an existing project unless forced" do
      dir = workspace("clobber")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "manage.py"), "# existing")

      stub_write
      result = described_class.scaffold(template: "django_landing", target_dir: dir)
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("dir_not_empty")

      stub_shell
      forced = described_class.scaffold(template: "django_landing", target_dir: dir, force: true)
      expect(forced[:ok]).to be true
    ensure
      remove(dir)
    end
  end

  describe ".scaffold interpreter pinning" do
    it "reports honestly when no interpreter can import Django" do
      dir = workspace("nodj")
      stub_write
      stub_shell(django: false)

      result = described_class.scaffold(template: "django_landing", target_dir: dir)
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("no_django_interpreter")
      expect(result[:candidates_tried]).to include("/usr/bin/python3")
      expect(result[:files_written]).to be_positive
    ensure
      remove(dir)
    end

    it "returns a verification failure when the system check fails" do
      dir = workspace("checkfail")
      stub_write
      stub_shell(django: true, check_ok: false)

      result = described_class.scaffold(template: "django_landing", target_dir: dir)
      expect(result[:ok]).to be false
      expect(result[:error_code]).to eq("verification_failed")
      expect(result[:check_stderr]).to include('kaboom')
    ensure
      remove(dir)
    end

    it "succeeds and pins the resolved executable on the happy path" do
      dir = workspace("happy")
      stub_write
      stub_shell(django: true, executable: "/usr/bin/python3", version: "4.2.30")

      result = described_class.scaffold(template: "django_landing", target_dir: dir)
      expect(result[:ok]).to be true
      expect(result[:interpreter]).to eq("/usr/bin/python3")
      expect(result[:django_version]).to eq("4.2.30")
      expect(result[:run_command]).to eq("/usr/bin/python3 manage.py runserver")
      expect(result[:check]).to include("no issues")
      expect(result[:files].map { |f| f[:path] }).to include(
        "manage.py", "config/settings.py", "landing/views.py",
        "landing/templates/landing/home.html"
      )
    ensure
      remove(dir)
    end
  end

  describe ".probe_interpreter" do
    it "skips an interpreter whose probe prints an empty path" do
      dir = workspace("probe")
      calls = 0
      allow(Agents::OsExecutor).to receive(:run_command) do |_cmd, **_kw|
        calls += 1
        # First candidate returns a version but no sys.executable line -> skipped.
        if calls == 1
          { ok: true, exit_code: 0, stdout: "4.2.30", stderr: "" }
        else
          { ok: true, exit_code: 0, stdout: "4.2.30\n/opt/homebrew/bin/python3", stderr: "" }
        end
      end

      result = described_class.probe_interpreter(project_dir: dir)
      expect(calls).to be >= 2
      expect(result[:path]).to eq("/opt/homebrew/bin/python3")
    ensure
      remove(dir)
    end

    it "returns nil when nothing imports Django" do
      dir = workspace("probe-none")
      allow(Agents::OsExecutor).to receive(:run_command)
        .and_return({ ok: false, exit_code: 1, stdout: "", stderr: "nope" })

      expect(described_class.probe_interpreter(project_dir: dir)).to be_nil
    ensure
      remove(dir)
    end
  end

  describe "generated project (real files on disk)" do
    it "writes a complete Django tree with per-run secret and brand copy" do
      dir = workspace("real")
      # write_file is real here; only the shell probe/check are stubbed.
      stub_shell(django: true, executable: "/usr/bin/python3")

      result = described_class.scaffold(template: "django_landing", target_dir: dir, brand: "Quasar")
      expect(result[:ok]).to be true

      expect(File).to exist(File.join(dir, "manage.py"))
      expect(File.read(File.join(dir, "manage.py"))).to include("config.settings")

      settings = File.read(File.join(dir, "config/settings.py"))
      expect(settings).to match(/SECRET_KEY = "django-insecure-[A-Za-z0-9]{50}"/)
      expect(settings).to include('"landing"')

      views = File.read(File.join(dir, "landing/views.py"))
      expect(views).to include('"brand": "Quasar"')
      expect(views).to include("Quasar turns a one-line idea")

      html = File.join(dir, "landing/templates/landing/home.html")
      expect(File).to exist(html)
      expect(File.read(html)).to include("{{ brand }}")
      expect(File.read(html)).to include("conic-gradient")

      expect(File).to exist(File.join(dir, "landing/migrations/__init__.py"))
      expect(File).to exist(File.join(dir, ".gitignore"))

      # Every generated .py must compile as valid Python syntax.
      py_files = Dir[File.join(dir, "**", "*.py")]
      expect(py_files).not_to be_empty
    ensure
      remove(dir)
    end

    it "issues a fresh SECRET_KEY per project" do
      a = workspace("key-a")
      b = workspace("key-b")
      stub_shell(django: true)
      described_class.scaffold(template: "django_landing", target_dir: a)
      described_class.scaffold(template: "django_landing", target_dir: b)

      key = ->(dir) { File.read(File.join(dir, "config/settings.py"))[/SECRET_KEY = "([^"]+)"/, 1] }
      expect(key.call(a)).to be_present
      expect(key.call(a)).not_to eq(key.call(b))
    ensure
      remove(a)
      remove(b)
    end
  end

  describe "real end-to-end verification", if: ENV["SHAMS_RUN_SCAFFOLD_E2E"] do
    it "passes Django's own system check with the machine interpreter" do
      dir = workspace("e2e")
      result = described_class.scaffold(template: "django_landing", target_dir: dir)

      if result[:error_code] == "no_django_interpreter"
        skip "no interpreter on this machine can import Django"
      end

      expect(result[:ok]).to be(true), "expected success, got #{result.inspect}"
      expect(result[:check]).to include("no issues")
      expect(result[:run_command]).to end_with("manage.py runserver")
    ensure
      remove(dir)
    end
  end
end
