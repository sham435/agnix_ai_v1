require "shellwords"

# The workspace facts as data.
#
# The web panel's JSON actions and the mobile API answer from here, so a phone
# and a browser see one serialization of the same sandbox: the same state, the
# same preview link, the same run history and the same refusal words.
module WorkspaceResponses
  extend ActiveSupport::Concern

  MAX_COMMAND_TOKENS = 32
  MIN_PREVIEW_PORT = 1024
  MAX_PREVIEW_PORT = 65_535

  included do
    rescue_from Workspaces::Unavailable, with: :render_workspace_unavailable
    rescue_from Workspaces::Rejected, with: :render_workspace_rejected
  end

  private

  def workspace_json(workspace)
    {
      id: workspace.id,
      name: workspace.name,
      runtime: workspace.runtime,
      state: workspace.state,
      conversation_id: workspace.conversation_id,
      preview: active_preview_json(workspace),
      last_error: workspace.last_error,
      created_at: workspace.created_at,
      updated_at: workspace.updated_at
    }
  end

  # The preview link is the gateway route with this session's token already on
  # it: it only works for the workspace that issued it, and only until it
  # expires. A client that cannot keep a cookie still gets a live link.
  def active_preview_json(workspace)
    preview = workspace.preview_sessions.active.order(created_at: :desc).first
    return nil unless preview

    {
      url: preview.gateway_path,
      port: preview.port,
      expires_at: preview.expires_at,
      seconds_left: preview.seconds_left
    }
  end

  def run_json(run)
    {
      id: run.id,
      kind: run.kind,
      argv: run.argv,
      ok: run.ok,
      exit_code: run.exit_code,
      timed_out: run.timed_out,
      duration_ms: run.duration_ms,
      stdout: run.stdout,
      stderr: run.stderr,
      created_at: run.created_at
    }
  end

  # Reading the sandbox's state must never break a screen: an unavailable
  # manager is reported as such and the caller still gets its run history.
  def safe_status
    Workspaces::Provider.workspace_status(@workspace)
  rescue Workspaces::Unavailable, Workspaces::Rejected => e
    { "state" => "unavailable", "error" => e.message }
  end

  # The workspace a route named, or nothing rendered: every action is keyed by
  # an id that must belong to the signed-in user, and a foreign or missing uuid
  # is answered the same way so one tells nothing about the other.
  def load_workspace
    @workspace = Workspace.where(user: current_user).find_by(id: params[:id])
    return if @workspace

    render_json_failure(:not_found, "workspace_not_found", "no such workspace for this account")
  end

  # argv travels as an array of tokens, exactly as the manager expects: no shell
  # ever parses it, so a filename with spaces or quotes needs no escaping.
  def command_argv
    argv = params[:argv]
    if argv.is_a?(Array)
      # A form field left blank arrives as one empty token, and a command made
      # of nothing is not a command: the manager would hand "" to execve.
      return nil unless argv.any? { |token| token.is_a?(String) && token.strip.present? } &&
                        argv.all?(String) &&
                        argv.length <= MAX_COMMAND_TOKENS

      return argv
    end
    return nil unless params[:command].to_s.strip.present?

    typed_command
  end

  # A single command field is split into argv tokens here — a shell lexer, not a
  # shell: nothing reaches /bin/sh, and unbalanced quotes are refused rather
  # than guessed at.
  def typed_command
    Shellwords.shellsplit(params[:command].to_s.strip).first(MAX_COMMAND_TOKENS).presence
  rescue ArgumentError
    nil
  end

  def timeout_param
    value = params[:timeout].to_i
    value.positive? ? value.clamp(1, 300) : nil
  end

  def valid_port?(port)
    Integer(port).between?(MIN_PREVIEW_PORT, MAX_PREVIEW_PORT)
  rescue ArgumentError, TypeError
    false
  end

  def render_json_failure(status, code, message)
    render json: { ok: false, error_code: code, error: message }, status: status
  end

  def render_workspace_unavailable(error)
    render_json_failure(:service_unavailable, "execution_unavailable", error.message)
  end

  def render_workspace_rejected(error)
    render_json_failure(error.status.between?(400, 599) ? error.status : 502,
                        "workspace_refused", error.message)
  end
end
