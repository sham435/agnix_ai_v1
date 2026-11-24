# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

# The Coding Workspace panel is the browser's window into a sandbox it cannot
# address directly: it is keyed by a workspace id owned by the signed-in user,
# it shows only what the manager confirmed, and every control in it answers by
# redrawing the panel rather than by navigating the conversation away.
RSpec.describe "Workspace panel", type: :request do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:workspace) { create(:workspace, user: user, conversation: conversation, name: "Flask landing page") }

  # The panel is a turbo frame; a request without its header renders the
  # whole page and proves nothing about what the panel itself shows.
  def frame
    { "Turbo-Frame" => "workspace_panel_body" }
  end

  def form_headers
    frame.merge("Accept" => "text/html", "X-CSRF-Token" => api_headers["X-CSRF-Token"])
  end

  def panel(section: nil, **query)
    get workspace_panel_path(query.merge(section ? { section: section } : {}),
                             conversation_id: conversation.id), headers: frame
  end

  describe "opening it" do
    it "asks an anonymous visitor to sign in" do
      get workspace_panel_path(conversation_id: conversation.id)
      expect(response).to have_http_status(:redirect)
    end

    context "when signed in" do
      before { api_login(user) }

      it "explains itself when this chat has no sandbox yet" do
        allow(Workspaces::Provider).to receive(:available?).and_return({ manager: true, docker: true })

        panel

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No workspace yet")
        expect(response.body).not_to include("workspace-panel__tab--active")
      end

      it "says the truth when the manager is not answering" do
        allow(Workspaces::Provider).to receive(:available?).and_return({ manager: false, docker: false })

        panel

        expect(response.body).to include("Execution is unavailable")
        expect(response.body).to include("workspace manager is not answering")
      end

      it "shows the sandbox this conversation owns, with its five tabs" do
        workspace
        allow(Workspaces::Provider).to receive_messages(
          workspace_status: { "state" => "running" },
          list_files: { ok: true, files: [], truncated: false }
        )

        panel

        expect(response.body).to include("Flask landing page")
        %w[Files Preview Terminal Logs Tests].each do |tab|
          expect(response.body).to include(">#{tab}<")
        end
        expect(response.body).to include("workspace-panel__tab--active")
      end

      it "refuses to render another account's workspace" do
        theirs = create(:workspace, user: other)

        get workspace_path(theirs)

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["error_code"]).to eq("workspace_not_found")
      end
    end
  end

  describe "the tabs" do
    before do
      api_login(user)
      workspace
      allow(Workspaces::Provider).to receive(:workspace_status).and_return({ "state" => "running" })
    end

    it "lists files and opens one without ever naming a host path" do
      allow(Workspaces::Provider).to receive(:list_files)
        .and_return({ ok: true, files: [ { path: "my folder/hello world.py", bytes: 12 } ], truncated: false })
      allow(Workspaces::Provider).to receive(:read_file)
        .with(workspace, "my folder/hello world.py")
        .and_return({ ok: true, path: "my folder/hello world.py", bytes: 12, content: "print(1)\n", truncated: false })

      get workspace_path(workspace, section: "files", path: "my folder/hello world.py"), headers: frame

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("my folder/hello world.py")
      expect(response.body).to include("print(1)")
      expect(Workspaces::Provider).to have_received(:read_file).with(workspace, "my folder/hello world.py")
    end

    it "shows the running preview through the gateway link, not a host port" do
      preview = create(:workspace_preview_session, workspace: workspace, port: 8000)
      allow(Workspaces::Provider).to receive(:preview_state).and_return({ "state" => "running" })

      get workspace_path(workspace, section: "preview"), headers: frame

      expect(response.body).to include(%(src="/workspaces/#{workspace.id}/preview/8000?session=#{preview.token}"))
      expect(response.body).not_to include("127.0.0.1")
      expect(response.body).to include("forwards HTTP only")
    end

    it "shows the last executions the manager answered for" do
      create(:workspace_run, workspace: workspace, argv: [ "python3", "-V" ], stdout: "Python 3.12")

      get workspace_path(workspace, section: "terminal"), headers: frame

      expect(response.body).to include("python3 -V")
      expect(response.body).to include("Python 3.12")
      expect(response.body).to include("exit 0")
    end

    it "shows the preview container's own logs" do
      allow(Workspaces::Provider).to receive(:preview_logs)
        .and_return({ "stdout" => " * Running on http://127.0.0.1:8000", "stderr" => "" })

      get workspace_path(workspace, section: "logs"), headers: frame

      expect(response.body).to include("Running on http://127.0.0.1:8000")
    end

    it "keeps test runs and exec runs apart" do
      create(:workspace_run, workspace: workspace, kind: "test", argv: [ "python3", "-m", "pytest", "-q" ],
                             stdout: "1 passed")
      create(:workspace_run, workspace: workspace, kind: "exec", argv: [ "ls" ], stdout: "app.py")

      get workspace_path(workspace, section: "tests"), headers: frame

      expect(response.body).to include("1 passed")
      expect(response.body).not_to include("app.py")
    end

    it "shows an unavailable manager as a line of text, not an error page" do
      allow(Workspaces::Provider).to receive(:list_files)
        .and_raise(Workspaces::Unavailable, "the workspace manager is not reachable")

      get workspace_path(workspace, section: "files"), headers: frame

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("the workspace manager is not reachable")
    end
  end

  describe "controls inside the frame" do
    before do
      api_login(user)
      workspace
      allow(Workspaces::Provider).to receive(:workspace_status).and_return({ "state" => "running" })
    end

    it "runs a typed command as argv tokens and redraws the terminal" do
      allow(Workspaces::Provider).to receive(:execute_command)
        .with(workspace, [ "python3", "my folder/app.py" ], timeout: anything)
        .and_return({ ok: true, exit_code: 0, duration_seconds: 0.2, stdout: "", stderr: "", timed_out: false })

      post workspace_exec_path(workspace),
           params: { "command" => %(python3 "my folder/app.py") },
           headers: form_headers

      expect(response).to have_http_status(:see_other)
      expect(response.location).to include("section=terminal")
    end

    it "refuses an unbalanced command line instead of guessing" do
      allow(Workspaces::Provider).to receive(:execute_command)

      post workspace_exec_path(workspace),
           params: { "command" => 'python3 "unbalanced' },
           headers: form_headers

      expect(response).to have_http_status(:bad_request)
      expect(Workspaces::Provider).not_to have_received(:execute_command)
    end

    it "starts a preview and hands the frame back to the preview tab" do
      allow(Workspaces::Provider).to receive(:start_preview)
        .with(workspace, port: 8000, command: "python3 app.py")
        .and_return({ ok: true, port: 8000, preview_url: "/preview" })

      post workspace_preview_start_path(workspace),
           params: { "port" => "8000", "command" => "python3 app.py" },
           headers: form_headers

      expect(response).to have_http_status(:see_other)
      expect(response.location).to include("section=preview")
    end

    it "downloads the ZIP the manager built" do
      allow(Workspaces::Provider).to receive(:export_project)
        .and_return({ ok: true, archive: "PK\x03\x04fake-zip".b, bytes: 12 })

      get workspace_export_path(workspace)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/zip")
      expect(response.body).to start_with("PK")
    end

    it "stops the workspace and shows the panel as stopped, not as a live sandbox" do
      allow(Workspaces::Provider).to receive(:destroy_workspace) do |target|
        target.record_state!("destroyed")
        { "ok" => true }
      end

      delete workspace_path(workspace), headers: form_headers

      expect(response).to have_http_status(:see_other)
      expect(response.location).to include("section=files")

      follow_redirect!
      expect(response.body).to include("Workspace stopped")
      expect(response.body).not_to include("workspace-panel__tab")
      expect(response.body).not_to include("Download ZIP")
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
