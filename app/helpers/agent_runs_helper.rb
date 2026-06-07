module AgentRunsHelper
  def status_badge_classes(status)
    case status.to_s
    when "planning"                then "bg-blue-500/15 text-blue-300 border-blue-500/30"
    when "awaiting_approval",
         "awaiting_confirmation"   then "bg-amber-500/15 text-amber-300 border-amber-500/30"
    when "executing"               then "bg-orange-500/15 text-orange-300 border-orange-500/30"
    when "completed"               then "bg-emerald-500/15 text-emerald-300 border-emerald-500/30"
    when "interrupted"             then "bg-red-500/15 text-red-300 border-red-500/30"
    else                                "bg-zinc-500/15 text-zinc-300 border-zinc-500/30"
    end
  end

  def mode_badge_classes(mode)
    case mode.to_s
    when "manual_plan"  then "bg-amber-500/15 text-amber-300 border-amber-500/30"
    when "auto_plan"    then "bg-sky-500/15 text-sky-300 border-sky-500/30"
    when "manual_build" then "bg-violet-500/15 text-violet-300 border-violet-500/30"
    when "auto_build"   then "bg-emerald-500/15 text-emerald-300 border-emerald-500/30"
    else                     "bg-zinc-500/15 text-zinc-300 border-zinc-500/30"
    end
  end

  def run_started_at(run)
    run.created_at.iso8601
  end
end
