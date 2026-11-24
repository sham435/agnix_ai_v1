module Workspaces
  # Shared shape for the workspace agent tools: resolve ownership, then translate
  # the two failure kinds into bounded results. A tool never raises into the
  # runner, and never reports work that the manager did not confirm.
  module ToolSupport
    module_function

    def with_workspace(context, workspace_id = nil, auto_create: false)
      resolution = ToolResolver.resolve(context, workspace_id: workspace_id, auto_create: auto_create)
      return resolution.error if resolution.workspace.nil?

      yield(resolution.workspace)
    rescue Unavailable => e
      { ok: false, error_code: "execution_unavailable", error: e.message }
    rescue Rejected => e
      { ok: false, error_code: "workspace_refused", status: e.status, error: e.message }
    end

    # The preview URL the user actually clicks: same-origin through Rails, so the
    # gateway still owns authentication and expiry.
    def preview_link(session_path)
      "#{ENV.fetch("SHAMS_WS_PUBLIC_BASE", "")}#{session_path}"
    end
  end
end
