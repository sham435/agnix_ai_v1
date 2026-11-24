module Workspaces
  # How an agent tool turns its call context into a Workspace it is allowed to
  # touch. Ownership lives here, not in each tool: a tool can only ever reach a
  # workspace belonging to the acting user, and the id it accepts is the
  # workspace's own uuid — never a host path.
  class ToolResolver
    Result = Struct.new(:workspace, :error, keyword_init: true)

    class << self
      def resolve(context, workspace_id: nil, auto_create: false)
        user = Agents::ToolRegistry::ToolContext.user_for(context)
        return denied("not_authorized", "no signed-in user is attached to this run") if user.nil?

        conversation = Conversation.find_by(id: context[:conversation_id]) if context[:conversation_id]
        scope = Workspace.where(user: user)

        if workspace_id.present?
          workspace = scope.find_by(id: workspace_id.to_s)
          # A foreign or malformed id looks identical to a missing one: the tool
          # never learns whether someone else's workspace exists.
          return denied("workspace_not_found", "no workspace #{workspace_id} belongs to this account") if workspace.nil?
          return finish(workspace)
        end

        if conversation
          # A destroyed sandbox is not the sandbox this chat is running in;
          # falling back to create is what lets the agent restart a stopped one.
          workspace = scope.where(conversation: conversation).where(destroyed_at: nil)
                           .where.not(state: "destroyed").order(created_at: :desc).first
          return finish(workspace) if workspace
          return create_for(conversation, user) if auto_create
        end

        denied("no_workspace", "this conversation has no workspace yet — call workspace_create first")
      end

      private

      def create_for(conversation, user)
        workspace = Provider.ensure_for(conversation: conversation, user: user)
        finish(workspace)
      rescue Unavailable => e
        denied("execution_unavailable", e.message)
      rescue Rejected => e
        denied("workspace_create_failed", e.message)
      end

      def finish(workspace)
        return denied("workspace_destroyed", "this workspace has already been destroyed") if workspace.destroyed_at? || workspace.state == "destroyed"

        Result.new(workspace: workspace)
      end

      def denied(code, message)
        Result.new(
          error: {
            ok: false,
            error_code: code,
            error: message,
            note: "Report this to the user as-is; do not describe work that did not happen."
          }
        )
      end
    end
  end
end
