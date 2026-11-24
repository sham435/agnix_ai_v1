require "shellwords"

module Workspaces
  # The one workspace API the rest of the app uses: create, get, status, write,
  # read, list, execute, run_tests, start_preview, stop_preview, export, destroy
  # (plus install, which the preview and test steps depend on).
  #
  # Everything is addressed by a Workspace record — whose id *is* the manager's
  # workspace id — and a path relative to /workspace. No method takes a host
  # directory, because Rails has no host directory to give.
  #
  # Two rules hold throughout:
  #   * an unreachable manager raises Unavailable, so the caller reports
  #     "execution capability unavailable" instead of inventing a success;
  #   * success is only claimed after the manager confirms the fact that makes
  #     it true: the container running, the byte count on disk, the port
  #     answering.
  class Provider
    class << self
      def available?
        health = ManagerClient.get("/healthz")
        { manager: true, docker: !!health["docker"] }
      rescue Unavailable
        { manager: false, docker: false }
      end

      def create_workspace(workspace)
        result = ManagerClient.post("/workspaces", { id: workspace.manager_id, runtime: workspace.runtime })
        status = result.dig("status", "state")
        if status == "running"
          workspace.record_state!("ready")
        else
          workspace.record_state!("failed", error: "manager reported #{status.inspect}")
          raise Unavailable, "the manager did not confirm a running workspace (state: #{status.inspect})"
        end
        workspace_status(workspace)
      end

      def get_workspace(workspace)
        workspace_status(workspace)
      end

      def workspace_status(workspace)
        result = ManagerClient.get(workspaces_path(workspace))
        state = result["state"] == "running" ? "ready" : result["state"]
        # A missing container is only news if the sandbox was supposed to be
        # there: a stopped workspace stays stopped.
        state = "failed" if state == "absent" && !workspace.destroyed_at?
        workspace.record_state!(state) if Workspace::STATES.include?(state) && workspace.state != state
        result
      rescue Rejected => e
        workspace.record_state!("failed", error: e.message)
        raise
      end

      def write_file(workspace, path, content)
        result = ManagerClient.post(workspaces_path(workspace, "/files"),
                                    { path: path, content_b64: [ content.to_s ].pack("m0") })
        unless result["ok"] && result["bytes"].to_i == content.to_s.bytesize
          raise Unavailable, "the manager did not confirm the write for #{path}"
        end
        { ok: true, path: result["path"], bytes: result["bytes"] }
      end

      def read_file(workspace, path)
        result = ManagerClient.get(workspaces_path(workspace, "/contents"), path: path)
        {
          ok: true,
          path: result["path"],
          bytes: result["bytes"],
          content: result["content_b64"].to_s.unpack1("m").force_encoding("UTF-8"),
          truncated: !!result["truncated"]
        }
      end

      def list_files(workspace, limit: nil)
        result = ManagerClient.get(workspaces_path(workspace, "/files"), limit ? { limit: limit } : {})
        {
          ok: true,
          files: Array(result["files"]).map { |entry| { path: entry["path"], bytes: entry["bytes"] } },
          truncated: !!result["truncated"]
        }
      end

      def execute_command(workspace, argv, timeout: nil, env: nil, kind: "exec")
        body = { argv: Array(argv).map(&:to_s) }
        body[:timeout] = timeout if timeout
        body[:env] = env if env.is_a?(Hash) && env.any?
        result = execution_result(ManagerClient.post(workspaces_path(workspace, "/exec"), body))
        WorkspaceRun.record!(workspace: workspace, kind: kind, argv: body[:argv], result: result)
        result
      end

      def install_dependencies(workspace, requirements, timeout: 300)
        result = ManagerClient.post(workspaces_path(workspace, "/install"),
                                    { requirements: requirements.to_s, timeout: timeout })
        installed = Array(result["installed"])
        WorkspaceRun.record!(
          workspace: workspace, kind: "install", argv: [ "pip", "install", "-r", "requirements.txt" ],
          result: { ok: !!result["ok"], exit_code: nil, duration_seconds: nil,
                    stdout: installed.join(", "), stderr: result["ok"] ? nil : result["output"],
                    timed_out: false }
        )
        { ok: !!result["ok"], installed: installed, output: result["output"].to_s }
      end

      def run_tests(workspace, command: nil, timeout: 120)
        argv = command.present? ? argv_for(command) : default_test_argv(workspace)
        result = execute_command(workspace, argv, timeout: timeout, kind: "test")
        {
          ok: result[:ok],
          command: argv.join(" "),
          exit_code: result[:exit_code],
          output: [ result[:stdout], result[:stderr] ].map(&:to_s).reject(&:empty?).join("\n"),
          timed_out: result[:timed_out],
          duration_seconds: result[:duration_seconds]
        }
      end

      def start_preview(workspace, port:, command: nil, timeout: 60)
        argv = command.present? ? argv_for(command) : [ "python3", "app.py" ]
        result = ManagerClient.post(workspaces_path(workspace, "/preview"),
                                    { argv: argv, port: port.to_i })
        # The manager only says ok once something inside the workspace actually
        # answered on that port, so a preview link is never a promise.
        raise Unavailable, "the manager could not reach port #{port} inside the workspace" unless result["ok"]

        session = WorkspacePreviewSession.issue!(workspace: workspace, port: port.to_i)
        {
          ok: true,
          port: session.port,
          preview_url: preview_url(session),
          expires_in: session.seconds_left,
          preview_session_token: session.token
        }
      end

      def stop_preview(workspace)
        result = ManagerClient.delete(workspaces_path(workspace, "/preview"))
        { ok: !!result["ok"], preview: result["preview"] }
      end

      def preview_state(workspace)
        ManagerClient.get(workspaces_path(workspace, "/preview"))
      end

      def preview_logs(workspace, tail: 200)
        ManagerClient.get(workspaces_path(workspace, "/logs"), { tail: tail })
      end

      def forward_preview(session, method:, sub_path: "", query: {}, headers: {}, body: nil)
        status, response_headers, response_body = ManagerClient.raw(
          method, "/preview/#{session.workspace.manager_id}/#{session.port}/#{sub_path}",
          query: query, headers: headers, body: body
        )
        session.note_request!
        { status: status, headers: response_headers, body: response_body }
      end

      def export_project(workspace)
        result = ManagerClient.get(workspaces_path(workspace, "/export"))
        archive = result["content_b64"].to_s.unpack1("m")
        raise Unavailable, "the manager returned an empty archive" if archive.bytesize.zero?

        WorkspaceRun.record!(
          workspace: workspace, kind: "export", argv: [ "export" ],
          result: { ok: true, exit_code: nil, duration_seconds: nil,
                    stdout: "#{archive.bytesize} bytes", stderr: nil, timed_out: false }
        )
        { ok: true, archive: archive, bytes: archive.bytesize }
      end

      def destroy_workspace(workspace, purge_volume: true)
        result = ManagerClient.delete("/workspaces/#{workspace.manager_id}", { volume: purge_volume ? "1" : "0" })
        workspace.preview_sessions.where(revoked_at: nil).update_all(revoked_at: Time.current)
        workspace.record_state!(result["container_removed"] ? "destroyed" : "failed",
                                error: result["container_removed"] ? nil : "manager could not remove the container")
        result
      end

      # The workspace a conversation runs in, created on first use. Callers get
      # back a record whose state the manager has already confirmed, or an
      # Unavailable they must report honestly.
      def ensure_for(conversation:, user:, name: nil)
        existing = Workspace.where(conversation: conversation, user: user).order(created_at: :desc).first
        return existing if existing && existing.state != "destroyed" && existing.destroyed_at.nil?

        # A stopped sandbox leaves one row per chat behind by design: the same
        # record is restarted, so its id — which is the container and volume name
        # the manager already knows — stays stable across a stop/start cycle.
        workspace = existing || Workspace.create!(
          user: user,
          conversation: conversation,
          name: (name.presence || conversation.title.presence || "Workspace").truncate(120),
          runtime: "python3"
        )
        workspace.record_state!("pending")
        begin
          create_workspace(workspace)
        rescue Unavailable, Rejected => e
          workspace.record_state!("failed", error: e.message)
          raise
        end
        workspace
      end

      private

      def workspaces_path(workspace, suffix = "")
        "/workspaces/#{workspace.manager_id}#{suffix}"
      end

      def execution_result(raw)
        {
          ok: !!raw["ok"],
          exit_code: raw["exit_code"],
          duration_seconds: raw["duration_seconds"],
          stdout: raw["stdout"].to_s,
          stderr: raw["stderr"].to_s,
          timed_out: !!raw["timed_out"]
        }
      end

      # The manager takes argv, never a shell line, so a command written by the
      # model is split into tokens here and each one travels as its own argument.
      def argv_for(command)
        Shellwords.shellsplit(command.to_s).first(32).presence || [ command.to_s ]
      rescue ArgumentError
        [ command.to_s ]
      end

      def default_test_argv(workspace)
        paths = list_files(workspace)[:files].to_a.map { |file| file[:path].to_s }
        if paths.any? { |path| path == "pytest.ini" || path == "pyproject.toml" || path.start_with?("tests/") }
          [ "python3", "-m", "pytest", "-q" ]
        else
          [ "python3", "-m", "unittest", "discover", "-v" ]
        end
      rescue Unavailable, Rejected
        [ "python3", "-m", "unittest", "discover", "-v" ]
      end

      def preview_url(session)
        session.gateway_path
      end
    end
  end
end
