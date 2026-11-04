# app/helpers/dev/processes_helper.rb
#
# Presentation for the process table. The numbers themselves come from
# `Dev::ProcessTable` (and behind it from the transitions recorded on the run
# row); this module only decides how a millisecond figure is written down.
module Dev
  module ProcessesHelper
    # A duration the way a scheduler would state it: milliseconds while it is
    # still short enough to care about, seconds to one decimal, then minutes.
    # nil is "—" — the transition was never recorded — which must never be
    # rendered as 0, because 0 reads as "instant" and hides the gap in the data.
    def format_ms(ms)
      return "—" if ms.nil?
      return "#{ms}ms" if ms < 1_000

      secs = ms / 1_000.0
      return "#{secs.round(1)}s" if secs < 60

      "#{(secs / 60).floor}m #{(secs % 60).round(1)}s"
    end

    # How wide to draw a wait bar. Buckets instead of a computed pixel width:
    # the CSP nonce cancels inline styles, so only utility classes can carry a
    # value from the database to the screen.
    def wait_bar_class(ms, longest)
      return "w-2" unless ms && longest && longest.positive?

      ratio = ms.to_f / longest
      case ratio
      when 0.75.. then "w-64"
      when 0.5.. then "w-40"
      when 0.25.. then "w-24"
      when 0.1.. then "w-12"
      else "w-6"
      end
    end

    def state_chip(row)
      label = if !row.measured?
        "untracked"
      elsif row.state == "exited"
        row.exit_note.to_s.start_with?("failed") ? "failed" : "exited"
      else
        row.state
      end

      tone = case label
      when "failed" then "border-red-500/30 text-red-600 dark:text-red-400"
      when "exited" then "border-border-subtle text-fg-muted"
      when "blocked" then "border-amber-500/30 text-amber-600 dark:text-amber-400"
      else "border-border-subtle text-accent-text"
      end

      tag.span label, class: "inline-flex items-center rounded-full border bg-panel px-2 py-0.5 text-[11px] whitespace-nowrap #{tone}"
    end
  end
end
