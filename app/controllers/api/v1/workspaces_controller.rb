# The Coding Workspace as data, for the mobile screen.
#
# Same provider, same ownership rules and same refusal words as the web panel:
# every action addresses one workspace row of the signed-in account, and only
# `Workspaces::Provider` reaches the manager. A conversation's sandbox is not a
# place a client can name — it is whatever this account's chat last ran in.
class Api::V1::WorkspacesController < ApplicationController
  include WorkspaceResponses

  MOBILE_FILE_LIMIT = 100
  MOBILE_RUN_LIMIT = 20

  before_action :authenticate_user!
  before_action :load_workspace, except: :index
  before_action :refuse_stopped_workspace, only: [ :file, :exec, :tests, :start_preview, :destroy ]

  # The sandboxes this account owns, or the one a single conversation runs in
  # when the client came from a chat.
  def index
    workspaces = Workspace.where(user: current_user)
    if params[:conversation_id].present?
      conversation = Conversation.where(user: current_user).find_by(id: params[:conversation_id])
      workspaces = conversation ? workspaces.where(conversation: conversation) : workspaces.none
    end
    render json: {
      ok: true,
      workspaces: workspaces.order(created_at: :desc).limit(20).map { |workspace| workspace_json(workspace) }
    }
  end

  # Everything the screen draws, in one read: the row, what the manager says
  # about the container (its payload already carries the preview state), the
  # project files and the recent run history.
  def show
    status = safe_status
    files = list_payload

    render json: {
      ok: true,
      workspace: workspace_json(@workspace),
      status: status,
      preview: status["preview"],
      files: files[:files],
      files_truncated: files[:truncated],
      files_error: files[:error],
      runs: @workspace.runs.recent.limit(MOBILE_RUN_LIMIT).map { |run| run_json(run) }
    }
  end

  def file
    result = Workspaces::Provider.read_file(@workspace, params[:path])
    render json: { ok: true, path: result[:path], content: result[:content], truncated: result[:truncated] }
  end

  def runs
    render json: { ok: true, runs: @workspace.runs.recent.limit(50).map { |run| run_json(run) } }
  end

  def exec
    argv = command_argv
    return render_json_failure(:bad_request, "argv_required", "argv must be a non-empty array of strings") if argv.nil?

    render json: Workspaces::Provider.execute_command(@workspace, argv, timeout: timeout_param)
  end

  def tests
    result = Workspaces::Provider.run_tests(@workspace, command: params[:command].presence,
                                                        timeout: timeout_param || 120)
    render json: result.merge(workspace_id: @workspace.id)
  end

  # The link is the gateway path plus this session's token; it only serves this
  # workspace and only until it expires.
  def start_preview
    port = params[:port].presence || 8000
    return render_json_failure(:bad_request, "port_invalid", "port must be between #{MIN_PREVIEW_PORT} and #{MAX_PREVIEW_PORT}") unless valid_port?(port)

    render json: Workspaces::Provider.start_preview(@workspace, port: Integer(port),
                                                                  command: params[:command].presence)
  end

  def stop_preview
    @workspace.preview_sessions.where(revoked_at: nil).update_all(revoked_at: Time.current)
    render json: Workspaces::Provider.stop_preview(@workspace)
  end

  def destroy
    result = Workspaces::Provider.destroy_workspace(@workspace)
    render json: { ok: true, workspace_id: @workspace.id, state: @workspace.state,
                   container_removed: result["container_removed"], volume_removed: result["volume_removed"] }
  end

  private

  # A stopped sandbox has no container to run code in, and the manager would
  # answer "workspace is absent" for a fact this app already knows. The screen
  # still reads its history; it just cannot execute against it.
  def refuse_stopped_workspace
    return unless @workspace.destroyed_at? || @workspace.state == "destroyed"

    render_json_failure(:conflict, "workspace_destroyed",
                        "this workspace has already been stopped; start a new turn in the chat to run it again")
  end

  def list_payload
    Workspaces::Provider.list_files(@workspace, limit: MOBILE_FILE_LIMIT)
  rescue Workspaces::Unavailable, Workspaces::Rejected => e
    { files: nil, truncated: false, error: e.message }
  end
end
