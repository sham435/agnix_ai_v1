# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

# The mobile workspace screen's data. The rules are the web panel's, seen from
# the other side of the wire: one account never sees another's sandbox, the
# container state shown is the manager's and not the column's, a stopped
# workspace is still readable but refuses to run code, and a preview link is
# only ever the gateway route this app issued.
RSpec.describe "API v1 workspaces", type: :request do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:workspace) { create(:workspace, user: user, conversation: conversation, name: "Flask landing page") }
  let(:stopped) { create(:workspace, user: user, state: "destroyed", destroyed_at: 2.hours.ago) }

  def json = JSON.parse(response.body)

  # A JSON body is the only way a client can send argv as an actual array; a
  # form-encoded one turns [] into a blank token and [1] into ["1"].
  def json_headers = api_headers.merge("CONTENT_TYPE" => "application/json")

  # What the manager answers for GET /workspaces/:id — including the preview
  # half, which is the container's own state and never a link.
  def status_payload(state: "running", preview: "absent")
    {
      "state" => state,
      "exit_code" => state == "exited" ? 1 : nil,
      "container" => state == "absent" ? nil : "shams-ws-#{workspace.id}",
      "preview" => { "state" => preview, "exit_code" => nil,
                     "container" => preview == "running" ? "shams-ws-#{workspace.id}-preview" : nil }
    }
  end

  describe "who may read it" do
    it "asks an anonymous client to sign in" do
      get "/api/v1/workspaces"

      expect(response).to have_http_status(:unauthorized)
    end

    it "lists only this account's workspaces" do
      create(:workspace, user: other, name: "Someone else's project")
      workspace
      api_login(user)

      get "/api/v1/workspaces", headers: api_headers

      expect(json["workspaces"].map { |row| row["name"] }).to eq([ "Flask landing page" ])
    end

    it "answers a foreign workspace id the same way as one that never existed" do
      foreign = create(:workspace, user: other)
      missing = SecureRandom.uuid
      api_login(user)

      get "/api/v1/workspaces/#{foreign.id}", headers: api_headers
      foreign_answer = json

      get "/api/v1/workspaces/#{missing}", headers: api_headers

      expect(foreign_answer).to eq(json)
      expect(response).to have_http_status(:not_found)
      expect(json).to include("ok" => false, "error_code" => "workspace_not_found")
    end

    it "filters to one conversation when the client came from a chat" do
      create(:workspace, user: user, name: "Another project")
      workspace
      api_login(user)

      get "/api/v1/workspaces", params: { conversation_id: conversation.id }, headers: api_headers

      expect(json["workspaces"].map { |row| row["id"] }).to eq([ workspace.id ])
    end

    it "lists nothing for a conversation this account does not own" do
      foreign_chat = create(:conversation, user: other, agent: agent)
      workspace
      api_login(user)

      get "/api/v1/workspaces", params: { conversation_id: foreign_chat.id }, headers: api_headers

      expect(json["workspaces"]).to be_empty
    end
  end

  describe "the screen snapshot" do
    before { api_login(user) }

    it "returns the row, the manager's state, the files and the run history together" do
      create(:workspace_run, workspace: workspace, kind: "exec", argv: [ "python3", "-V" ],
                             stdout: "Python 3.12.7")
      create(:workspace_run, workspace: workspace, kind: "test",
                             argv: [ "python3", "-m", "pytest", "-q" ])
      allow(Workspaces::Provider).to receive(:workspace_status).and_return(status_payload)
      allow(Workspaces::Provider).to receive(:list_files)
        .with(workspace, limit: 100)
        .and_return({ ok: true, files: [ { path: "app.py", bytes: 338 } ], truncated: false })

      get "/api/v1/workspaces/#{workspace.id}", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["workspace"]).to include(
        "id" => workspace.id,
        "name" => "Flask landing page",
        "state" => "ready",
        "conversation_id" => conversation.id
      )
      # The container's state is the manager's answer, not the column.
      expect(json["status"]).to include("state" => "running", "container" => "shams-ws-#{workspace.id}")
      expect(json["preview"]).to eq(status_payload["preview"])
      expect(json["files"]).to eq([ { "path" => "app.py", "bytes" => 338 } ])
      expect(json["files_truncated"]).to be(false)
      expect(json["runs"].map { |row| row["kind"] }).to contain_exactly("exec", "test")
      expect(json["runs"].find { |row| row["kind"] == "exec" })
        .to include("ok" => true, "exit_code" => 0, "stdout" => "Python 3.12.7")
    end

    it "carries the preview link this app issued, not one the client built" do
      issued = create(:workspace_preview_session, workspace: workspace)
      allow(Workspaces::Provider).to receive_messages(
        workspace_status: status_payload(preview: "running"),
        list_files: { ok: true, files: [], truncated: false }
      )

      get "/api/v1/workspaces/#{workspace.id}", headers: api_headers

      expect(json["workspace"]["preview"]).to include(
        "url" => "/workspaces/#{workspace.id}/preview/8000?session=#{issued.token}",
        "port" => 8000
      )
      expect(json["workspace"]["preview"]["seconds_left"]).to be > 0
    end

    it "still reads a workspace whose manager went silent" do
      allow(Workspaces::Provider).to receive(:workspace_status).and_raise(
        Workspaces::Unavailable, "workspace manager is not answering"
      )
      allow(Workspaces::Provider).to receive(:list_files).and_raise(
        Workspaces::Unavailable, "workspace manager is not answering"
      )

      get "/api/v1/workspaces/#{workspace.id}", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["status"]).to include("state" => "unavailable",
                                        "error" => "workspace manager is not answering")
      expect(json["preview"]).to be_nil
      expect(json["files"]).to be_nil
      expect(json["files_error"]).to eq("workspace manager is not answering")
    end

    it "shows a stopped workspace as stopped and keeps its history readable" do
      create(:workspace_run, workspace: stopped, kind: "test")
      allow(Workspaces::Provider).to receive(:workspace_status).and_return(status_payload(state: "absent"))
      allow(Workspaces::Provider).to receive(:list_files)
        .and_raise(Workspaces::Rejected.new(404, "workspace is absent"))

      get "/api/v1/workspaces/#{stopped.id}", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["workspace"]["state"]).to eq("destroyed")
      expect(json["files_error"]).to eq("workspace is absent")
      expect(json["runs"].map { |row| row["kind"] }).to eq([ "test" ])
    end
  end

  describe "files" do
    before { api_login(user) }

    it "hands a path to the provider and returns its content" do
      allow(Workspaces::Provider).to receive(:read_file)
        .with(workspace, "templates/index.html")
        .and_return({ ok: true, path: "templates/index.html", content: "<h1>Azmika</h1>", truncated: false })

      get "/api/v1/workspaces/#{workspace.id}/file", params: { path: "templates/index.html" }, headers: api_headers

      expect(json).to include("ok" => true, "path" => "templates/index.html", "truncated" => false)
      expect(json["content"]).to include("<h1>Azmika</h1>")
    end

    it "passes the manager's refusal through in its own words" do
      allow(Workspaces::Provider).to receive(:read_file)
        .and_raise(Workspaces::Rejected.new(400, "path escapes the workspace"))

      get "/api/v1/workspaces/#{workspace.id}/file", params: { path: "../secrets" }, headers: api_headers

      expect(response).to have_http_status(:bad_request)
      expect(json).to include("ok" => false, "error_code" => "workspace_refused",
                              "error" => "path escapes the workspace")
    end

    it "reports an unavailable manager instead of an empty file" do
      allow(Workspaces::Provider).to receive(:read_file)
        .and_raise(Workspaces::Unavailable, "workspace manager is not answering")

      get "/api/v1/workspaces/#{workspace.id}/file", params: { path: "app.py" }, headers: api_headers

      expect(response).to have_http_status(:service_unavailable)
      expect(json["error_code"]).to eq("execution_unavailable")
    end
  end

  describe "running a command" do
    before { api_login(user) }

    it "sends argv as tokens, with the timeout the client asked for" do
      argv = [ "python3", "-c", "print('hi')" ]
      allow(Workspaces::Provider).to receive(:execute_command)
        .with(workspace, argv, timeout: 20)
        .and_return({ ok: true, exit_code: 0, duration_seconds: 0.1, stdout: "hi\n", stderr: "",
                      timed_out: false })

      post "/api/v1/workspaces/#{workspace.id}/exec",
           params: { argv: argv, timeout: 20 }, headers: api_headers

      expect(json).to include("ok" => true, "stdout" => "hi\n")
    end

    it "splits one typed command into argv without ever running a shell" do
      allow(Workspaces::Provider).to receive(:execute_command)
        .with(workspace, [ "python3", "run tests.py", "--verbose" ], timeout: nil)
        .and_return({ ok: true, exit_code: 0, duration_seconds: 0.2, stdout: "", stderr: "",
                      timed_out: false })

      post "/api/v1/workspaces/#{workspace.id}/exec",
           params: { command: 'python3 "run tests.py" --verbose' }, headers: api_headers

      expect(json["ok"]).to be(true)
    end

    it "refuses a command it cannot turn into argv" do
      allow(Workspaces::Provider).to receive(:execute_command)

      post "/api/v1/workspaces/#{workspace.id}/exec", params: { command: 'echo "unbalanced' }, headers: api_headers

      expect(response).to have_http_status(:bad_request)
      expect(json["error_code"]).to eq("argv_required")
      expect(Workspaces::Provider).not_to have_received(:execute_command)
    end

    it "refuses a command that is blank, empty or not made of strings" do
      allow(Workspaces::Provider).to receive(:execute_command)

      # A form field left blank is one empty token; execve("") is not a command.
      post "/api/v1/workspaces/#{workspace.id}/exec", params: { argv: [] }, headers: api_headers
      expect(json["error_code"]).to eq("argv_required")

      post "/api/v1/workspaces/#{workspace.id}/exec", params: { argv: [] }.to_json,
           headers: json_headers
      expect(json["error_code"]).to eq("argv_required")

      post "/api/v1/workspaces/#{workspace.id}/exec", params: { argv: [ 1 ] }.to_json,
           headers: json_headers
      expect(json["error_code"]).to eq("argv_required")
      expect(Workspaces::Provider).not_to have_received(:execute_command)
    end

    it "refuses to execute inside a workspace that has been stopped" do
      allow(Workspaces::Provider).to receive(:execute_command)

      post "/api/v1/workspaces/#{stopped.id}/exec", params: { argv: [ "python3", "-V" ] }, headers: api_headers

      expect(response).to have_http_status(:conflict)
      expect(json["error_code"]).to eq("workspace_destroyed")
      expect(Workspaces::Provider).not_to have_received(:execute_command)
    end
  end

  describe "tests, preview and stopping" do
    before { api_login(user) }

    it "runs the test command the provider chose and reports its result" do
      allow(Workspaces::Provider).to receive(:run_tests)
        .with(workspace, command: nil, timeout: 120)
        .and_return({ ok: true, command: "python3 -m pytest -q", exit_code: 0, output: "2 passed",
                      timed_out: false, duration_seconds: 1.2 })

      post "/api/v1/workspaces/#{workspace.id}/tests", headers: api_headers

      expect(json).to include("ok" => true, "command" => "python3 -m pytest -q",
                              "workspace_id" => workspace.id)
    end

    it "answers a started preview with the gateway link and its lifetime" do
      issued = create(:workspace_preview_session, workspace: workspace)
      allow(Workspaces::Provider).to receive(:start_preview)
        .with(workspace, port: 8000, command: nil)
        .and_return({ ok: true, port: issued.port, preview_url: issued.gateway_path,
                      expires_in: issued.seconds_left, preview_session_token: issued.token })

      post "/api/v1/workspaces/#{workspace.id}/preview", params: { port: 8000 }, headers: api_headers

      expect(json).to include(
        "ok" => true,
        "port" => 8000,
        "preview_url" => "/workspaces/#{workspace.id}/preview/8000?session=#{issued.token}"
      )
      expect(json["expires_in"]).to be > 0
    end

    it "refuses a port a workspace cannot be previewed on" do
      allow(Workspaces::Provider).to receive(:start_preview)

      post "/api/v1/workspaces/#{workspace.id}/preview", params: { port: 80 }, headers: api_headers

      expect(response).to have_http_status(:bad_request)
      expect(json["error_code"]).to eq("port_invalid")
      expect(Workspaces::Provider).not_to have_received(:start_preview)
    end

    it "revokes the live preview session when the client stops it" do
      preview = create(:workspace_preview_session, workspace: workspace)
      allow(Workspaces::Provider).to receive(:stop_preview)
        .and_return({ ok: true, preview: { "state" => "absent", "exit_code" => nil, "container" => nil } })

      delete "/api/v1/workspaces/#{workspace.id}/preview", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["preview"]["state"]).to eq("absent")
      expect(preview.reload.revoked_at).not_to be_nil
    end

    it "destroys the sandbox and reports what the manager removed" do
      allow(Workspaces::Provider).to receive(:destroy_workspace) do |target|
        target.record_state!("destroyed")
        { "container_removed" => true, "volume_removed" => true }
      end

      delete "/api/v1/workspaces/#{workspace.id}", headers: api_headers

      expect(json).to include("ok" => true, "state" => "destroyed",
                              "container_removed" => true, "volume_removed" => true)
      expect(workspace.reload.destroyed_at).not_to be_nil
    end

    it "refuses to destroy a workspace that is already stopped" do
      allow(Workspaces::Provider).to receive(:destroy_workspace)

      delete "/api/v1/workspaces/#{stopped.id}", headers: api_headers

      expect(response).to have_http_status(:conflict)
      expect(json["error_code"]).to eq("workspace_destroyed")
      expect(Workspaces::Provider).not_to have_received(:destroy_workspace)
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
