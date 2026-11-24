class WorkspacesController < ApplicationController
  include WorkspaceResponses

  # Every action here is keyed by a workspace id that must belong to the
  # signed-in user; there is no route that accepts a host path.
  before_action :authenticate_user!
  before_action :load_workspace, except: [ :index, :panel ]

  SECTIONS = %w[files preview terminal logs tests].freeze

  def index
    workspaces = Workspace.where(user: current_user).order(created_at: :desc).limit(20)
    render json: { workspaces: workspaces.map { |workspace| workspace_json(workspace) } }
  end

  # The Coding Workspace panel as opened from a conversation: whichever sandbox
  # this chat is running in, or an honest "nothing exists yet" if none does.
  def panel
    @conversation = Conversation.where(user: current_user).find_by(id: params[:conversation_id])
    latest = @conversation && Workspace.where(conversation: @conversation, user: current_user)
                                        .order(created_at: :desc).first
    # A destroyed sandbox is not a sandbox: the panel falls back to the empty
    # state and says so, instead of offering controls for a container that is gone.
    @stopped_workspace = latest if latest&.state == "destroyed"
    @workspace = latest unless @stopped_workspace
    @section = section_param
    @status = @workspace ? safe_status : nil
    load_section_data if @workspace
  end

  # The right-side Coding Workspace panel. HTML answers the turbo frame; JSON
  # answers clients that draw their own surface.
  def show
    @section = section_param
    respond_to do |format|
      format.html do
        @status = safe_status
        load_section_data
      end
      format.json { render json: workspace_json(@workspace).merge(safe_status) }
    end
  end

  def files
    result = Workspaces::Provider.list_files(@workspace, limit: params[:limit])
    render json: { ok: true, files: result[:files], truncated: result[:truncated] }
  end

  def file
    result = Workspaces::Provider.read_file(@workspace, params[:path])
    render json: { ok: true, path: result[:path], content: result[:content], truncated: result[:truncated] }
  end

  def logs
    logs = Workspaces::Provider.preview_logs(@workspace, tail: params[:tail] || 200)
    render json: {
      ok: true,
      stdout: logs["stdout"].to_s,
      stderr: logs["stderr"].to_s,
      preview: safe_status&.dig("preview"),
      runs: @workspace.runs.recent.limit(20).map { |run| run_json(run) }
    }
  end

  def runs
    render json: { ok: true, runs: @workspace.runs.recent.limit(50).map { |run| run_json(run) } }
  end

  # argv travels as an array of tokens, exactly as the manager expects: no shell
  # ever parses it, so a filename with spaces or quotes needs no escaping.
  def exec
    argv = command_argv
    return render_json_failure(:bad_request, "argv_required", "argv must be a non-empty array of strings") if argv.nil?

    result = Workspaces::Provider.execute_command(@workspace, argv, timeout: timeout_param)
    respond_to do |format|
      format.json { render json: result }
      format.html { redirect_back_to :terminal, result }
    end
  end

  def tests
    result = Workspaces::Provider.run_tests(@workspace, command: params[:command].presence,
                                                        timeout: timeout_param || 120)
    respond_to do |format|
      format.json { render json: result.merge(workspace_id: @workspace.id) }
      format.html { redirect_back_to :tests, result }
    end
  end

  def start_preview
    port = params[:port].presence || 8000
    return render_json_failure(:bad_request, "port_invalid", "port must be between #{MIN_PREVIEW_PORT} and #{MAX_PREVIEW_PORT}") unless valid_port?(port)

    result = Workspaces::Provider.start_preview(@workspace, port: Integer(port), command: params[:command].presence)
    respond_to do |format|
      format.json { render json: result }
      format.html { redirect_back_to :preview, result }
    end
  end

  def stop_preview
    @workspace.preview_sessions.where(revoked_at: nil).update_all(revoked_at: Time.current)
    result = Workspaces::Provider.stop_preview(@workspace)
    respond_to do |format|
      format.json { render json: result }
      format.html { redirect_back_to :preview, result }
    end
  end

  # The archive is built inside Docker from the workspace volume only and leaves
  # through this authenticated route.
  def export
    result = Workspaces::Provider.export_project(@workspace)
    send_data result[:archive],
              filename: "#{@workspace.name.parameterize.presence || "workspace"}-#{@workspace.id.first(8)}.zip",
              type: "application/zip",
              disposition: "attachment"
  end

  def destroy
    Workspaces::Provider.destroy_workspace(@workspace)
    respond_to do |format|
      format.json { render json: { ok: true, workspace_id: @workspace.id, state: @workspace.state } }
      format.html { redirect_to destroy_landing_path, status: :see_other, flash: { workspace_note: "stopped" } }
    end
  end

  private

  def section_param
    SECTIONS.include?(params[:section].to_s) ? params[:section] : "files"
  end

  # After a stop the frame goes back through the conversation, not straight to
  # the workspace: the panel decides that a destroyed sandbox is shown as
  # stopped, and the redirect target cannot lie about it.
  def destroy_landing_path
    if @workspace.conversation_id
      workspace_panel_path(conversation_id: @workspace.conversation_id, section: "files")
    else
      workspace_path(@workspace, section: "files")
    end
  end

  # A form inside the frame answers by pointing the frame at its own tab again,
  # so the panel always shows what the manager just confirmed rather than what
  # the browser hoped for.
  def redirect_back_to(section, result)
    note = result[:ok] ? "done" : (result[:error] || result[:error_code] || result[:note] || "the workspace refused")
    redirect_to workspace_path(@workspace, section: section), status: :see_other,
                flash: { workspace_note: note }
  end

  # Each tab reads only what it shows. Everything here is best-effort: an
  # unreachable manager is a line of text in the panel, never an exception page.
  def load_section_data
    @preview_session = @workspace.preview_sessions.active.order(created_at: :desc).first
    case @section
    when "files"
      @files = safe_call { Workspaces::Provider.list_files(@workspace, limit: 200) }
      @file = params[:path].presence && safe_call { Workspaces::Provider.read_file(@workspace, params[:path]) }
    when "preview"
      @preview_state = safe_call { Workspaces::Provider.preview_state(@workspace) }
    when "terminal"
      @runs = @workspace.runs.where(kind: "exec").recent.limit(6)
    when "logs"
      @logs = safe_call { Workspaces::Provider.preview_logs(@workspace, tail: 200) }
      @runs = @workspace.runs.recent.limit(8)
    when "tests"
      @runs = @workspace.runs.where(kind: "test").recent.limit(4)
    end
  end

  def safe_call
    yield
  rescue Workspaces::Unavailable => e
    { ok: false, error_code: "execution_unavailable", error: e.message }
  rescue Workspaces::Rejected => e
    { ok: false, error_code: "workspace_refused", error: e.message }
  end
end
