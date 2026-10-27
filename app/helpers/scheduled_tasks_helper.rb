# frozen_string_literal: true

# Presentation-only helpers for the /scheduled inbox. No database access lives
# here — counts and ordering come from model scopes, and these methods merely
# map an already-loaded ScheduledTask to display strings and Tailwind classes.
module ScheduledTasksHelper
  STATUS_CHIP_CLASSES = {
    "active"    => "bg-accent/15 text-accent border-accent/30",
    "paused"    => "bg-amber-500/15 text-amber-700 dark:text-amber-500 border-amber-500/30",
    "completed" => "bg-sky-500/15 text-sky-700 dark:text-sky-500 border-sky-500/30",
    "failed"    => "bg-red-500/15 text-red-700 dark:text-red-500 border-red-500/30",
    "cancelled" => "bg-zinc-500/15 text-fg-muted border-zinc-500/30"
  }.freeze

  RUN_CHIP_CLASSES = {
    "queued"    => "bg-zinc-500/15 text-fg-muted",
    "running"   => "bg-accent/15 text-accent",
    "succeeded" => "bg-accent/15 text-accent-text",
    "failed"    => "bg-red-500/15 text-red-700 dark:text-red-500"
  }.freeze

  def scheduled_status_chip(task)
    classes = STATUS_CHIP_CLASSES.fetch(task.status, STATUS_CHIP_CLASSES["cancelled"])
    tag.span(task.status.capitalize,
             class: "inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-medium #{classes}")
  end

  def scheduled_run_chip(run)
    return tag.span("No runs yet", class: "text-[12px] text-fg-subtle") if run.nil?

    classes = RUN_CHIP_CLASSES.fetch(run.status, "")
    tag.span("Last run #{run.status}", class: "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium #{classes}")
  end

  def scheduled_next_run_label(task)
    return "—" if task.next_run_at.blank?
    return "Finished" if task.completed? && task.next_run_at.nil?

    "#{time_in_zone(task.next_run_at, task.timezone)} · #{time_ago_in_words(task.next_run_at)} from now"
  end

  def scheduled_last_run_label(task)
    return "Never" if task.last_run_at.blank?

    time_in_zone(task.last_run_at, task.timezone)
  end

  # Render a UTC instant in the task's own zone for display. Presentation only.
  def time_in_zone(utc_time, zone)
    tz = ActiveSupport::TimeZone[zone.to_s] || ActiveSupport::TimeZone["UTC"]
    utc_time.in_time_zone(tz).strftime("%b %-d, %Y · %H:%M")
  rescue StandardError
    utc_time.to_s
  end

  def scheduled_timezone_options
    ActiveSupport::TimeZone.all.map { |z| [ "#{z.name} (#{z.formatted_offset})", z.name ] }.unshift([ "UTC", "UTC" ]).uniq { |o| o.last }
  end

  def scheduled_agent_options
    current_organization&.agents&.active&.map { |a| [ a.name, a.id ] } || []
  end
end
