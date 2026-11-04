# app/controllers/dev/processes_controller.rb
#
# The development process table: every recent agent run as a row, in the terms
# an operating system uses (state, queue wait, CPU burst, I/O wait, context
# switches, exit status). This is the "watch the agent the way you would watch
# `ps`" screen for the development stage — it exists so a slow turn can be
# attributed to the box being busy, the model being slow, or a tool blocking,
# without reading Rails logs by hand.
#
# Rendered from `Run#pcb_summary`, i.e. from the transitions recorded while the
# run was alive; nothing here re-derives history from the wall clock.
class Dev::ProcessesController < ApplicationController
  # `local?` and not `development?` because the request spec has to render this
  # page too. Production gets a 404, and the route is not even drawn there.
  before_action :ensure_local!
  before_action :authenticate_user!

  def index
    @table = Dev::ProcessTable.build(runs)
  end

  private

  def runs
    Run.order(created_at: :desc).limit(limit)
  end

  def limit
    params.fetch(:limit, 100).to_i.clamp(1, 500)
  end

  def ensure_local!
    raise ActiveRecord::RecordNotFound unless Rails.env.local?
  end
end
