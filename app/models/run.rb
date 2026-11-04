# == Schema Information
#
# Table name: runs
#
#  id              :uuid             not null, primary key
#  agent_id        :uuid             not null
#  conversation_id :uuid
#  input           :jsonb            not null
#  output          :jsonb
#  status          :string           default("pending"), not null
#  tokens_used     :integer          default(0)
#  started_at      :datetime
#  finished_at     :datetime
#  error_message   :text
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Run < ApplicationRecord
  belongs_to :agent, counter_cache: true
  belongs_to :conversation, optional: true, touch: true

  has_many :usage_events, dependent: :nullify

  enum :status, { pending: "pending", running: "running", succeeded: "succeeded", failed: "failed", cancelled: "cancelled" }, default: :pending

  validates :status, presence: true

  scope :active, -> { where(status: %w[pending running]) }
  scope :recent, -> { order(started_at: :desc) }

  # ── Process control block ──────────────────────────────────────────
  #
  # A run IS a process: it arrives, waits for a worker, runs, blocks on the
  # model socket or a tool, and exits. `status` keeps only the last few of
  # those, and keeps them as one word — which is why a five-minute turn and a
  # five-second one were indistinguishable after the fact. So every transition
  # is appended, with its timestamp, to `metadata["pcb"]`:
  #
  #   { "arrival_at"  => "2026-11-04T17:53:20.412Z",
  #     "dispatched_at" => "2026-11-04T17:53:21.001Z",
  #     "states" => [ { "state" => "new",  "at" => "...", "note" => nil },
  #                   { "state" => "ready","at" => "...", "note" => nil },
  #                   { "state" => "running", "at" => "...", "note" => nil },
  #                   { "state" => "blocked", "at" => "...",
  #                     "note" => "provider:openai/bonsai-227b" },
  #                   { "state" => "running", "at" => "...", "note" => "iteration 2" },
  #                   { "state" => "exited", "at" => "...", "note" => "completed" } ] }
  #
  # No migration: the transitions are the data, and everything the process
  # table shows is computed from them (see #pcb_summary).
  PCB_STATES = %w[new ready running blocked exited].freeze

  # Build the metadata a run is created with, so the history that happened
  # BEFORE the row existed is not lost: the arrival (the persisted user turn)
  # and the dispatch (the moment a worker picked the job up). `started_at` is
  # the RUNNING transition. Absent stamps are simply not recorded — a runner
  # used outside `AgentStreamJob` gets a run that starts at RUNNING, which is
  # honest rather than an invented queue time.
  def self.seed_pcb_metadata(arrival_at:, dispatched_at:, started_at:, base: {})
    states = []
    states << pcb_entry("new", arrival_at) if arrival_at
    states << pcb_entry("ready", dispatched_at) if dispatched_at
    states << pcb_entry("running", started_at)
    pcb = {
      "arrival_at" => arrival_at&.utc&.iso8601(3),
      "dispatched_at" => dispatched_at&.utc&.iso8601(3),
      "states" => states
    }.compact
    (base.is_a?(Hash) ? base : {}).merge("pcb" => pcb)
  end

  def self.pcb_entry(state, at, note = nil)
    { "state" => state.to_s, "at" => at.utc.iso8601(3), "note" => note }.compact
  end

  # Methods.
  def finish!(output:, tokens_used:, exit_note: "completed")
    update!(status: :succeeded, output: output, tokens_used: tokens_used, finished_at: Time.current)
    record_state!("exited", note: exit_note)
  end

  def fail!(error)
    update!(
      status: :failed,
      error_message: error.to_s,
      finished_at: Time.current
    )
    record_state!("exited", note: "failed: #{error}")
  end

  def cancel!
    update!(status: :cancelled, finished_at: Time.current)
    record_state!("exited", note: "cancelled")
  end

  def duration_seconds
    return nil unless started_at && finished_at
    (finished_at - started_at).to_i
  end

  def running?
    status == "running"
  end

  def completed?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end

  # Append one transition to the process control block.
  #
  # Read-modify-write under a row lock, because the runner, this job and
  # `finish!`/`fail!` all append to the same jsonb column: an unlocked
  # read-modify-write loses whichever append interleaved, and a lost transition
  # silently mis-states the numbers the dev process table is built from.
  #
  # `update_column` on purpose — a bookkeeping write must not fire
  # `touch: true` on the conversation (a run would keep hopping to the top of
  # the sidebar every time the model paused) nor re-validate a row that is
  # mid-flight.
  #
  # Instrumentation is never allowed to be the reason a run fails, so anything
  # the database throws here is logged and swallowed.
  def record_state!(state, note: nil, at: nil)
    name = state.to_s
    unless PCB_STATES.include?(name)
      Rails.logger.warn "[Run] PCB-RECORD-SKIPPED id=#{id} unknown state=#{name.inspect}"
      return self
    end

    stamp = at || Time.current
    with_lock do
      # A savepoint, not just the lock: this append runs inside whatever
      # transaction the run happens to live in, and a statement that fails
      # would otherwise abort that transaction for everything that comes after
      # it. Rolling back only this write is what keeps the promise below.
      transaction(requires_new: true) do
        fresh = metadata.is_a?(Hash) ? metadata.dup : {}
        block = fresh["pcb"].is_a?(Hash) ? fresh["pcb"].dup : {}
        timeline = Array(block["states"]).dup
        timeline << self.class.pcb_entry(name, stamp, note)
        block["states"] = timeline
        block["arrival_at"] ||= stamp.utc.iso8601(3) if name == "new"
        block["dispatched_at"] ||= stamp.utc.iso8601(3) if name == "ready"
        fresh["pcb"] = block
        update_column(:metadata, fresh)
      end
    end
    self
  rescue StandardError => e
    Rails.logger.warn "[Run] PCB-RECORD-FAILED id=#{id} state=#{name} #{e.class}: #{e.message}"
    self
  end

  # The recorded timeline, oldest first, with `at` parsed back into a Time.
  # Entries without a timestamp are dropped rather than guessed at.
  def pcb_timeline
    block = metadata.is_a?(Hash) ? metadata["pcb"] : nil
    entries = block.is_a?(Hash) ? Array(block["states"]) : []
    entries.filter_map do |entry|
      next unless entry.is_a?(Hash) && entry["at"].present?

      {
        state: entry["state"].to_s,
        at: Time.parse(entry["at"].to_s),
        note: entry["note"]
      }
    end.sort_by { |entry| entry[:at] }
  end

  # Everything a process table shows about this run, computed from the
  # timeline. An OS does not charge a process for time it is still owed, so
  # the interval after the LAST recorded transition is left uncounted: a run
  # that is mid-provider-call reports the burst it finished, not a duration
  # invented from the wall clock. Rows written before this instrumentation
  # simply have no states, and `recorded` is false.
  def pcb_summary
    timeline = pcb_timeline
    return { "recorded" => false, "states" => 0 } if timeline.empty?

    intervals = timeline.each_cons(2).map do |from, to|
      {
        state: from[:state],
        note: from[:note],
        ms: ((to[:at] - from[:at]) * 1000).round
      }
    end

    bursts = intervals.select { |i| i[:state] == "running" }
    blocks = intervals.select { |i| i[:state] == "blocked" }
    switches = intervals.count { |i| %w[running blocked].include?(i[:state]) }
    last = timeline.last
    arrived = timeline.first[:at]
    exited = timeline.reverse.find { |entry| entry[:state] == "exited" }

    {
      "recorded" => true,
      "states" => timeline.size,
      "arrival_at" => arrived,
      "dispatched_at" => timeline.find { |entry| entry[:state] == "ready" }&.dig(:at),
      "running_at" => timeline.find { |entry| entry[:state] == "running" }&.dig(:at),
      "exited_at" => exited&.dig(:at),
      "exit_note" => exited&.dig(:note),
      # Still alive: the newest transition is the state it is sitting in now.
      "current_state" => exited ? "exited" : last[:state],
      "current_note" => exited ? nil : last[:note],
      "queue_ms" => ms_between(timeline, "new", "ready"),
      "start_ms" => ms_between(timeline, "new", "running"),
      "turnaround_ms" => exited ? ((exited[:at] - arrived) * 1000).round : nil,
      "cpu_ms" => bursts.sum { |i| i[:ms] },
      "io_ms" => blocks.sum { |i| i[:ms] },
      "bursts" => bursts.size,
      "context_switches" => switches,
      "blocked_by" => blocks.group_by { |i| i[:note].presence || "unspecified" }
        .transform_values { |list| list.sum { |i| i[:ms] } }
        .sort_by { |_note, ms| -ms }.to_h
    }
  end

  private

  # Milliseconds between the first transition into each of two states, or nil
  # when either one was never recorded.
  def ms_between(timeline, first_state, second_state)
    from = timeline.find { |entry| entry[:state] == first_state }
    to = timeline.find { |entry| entry[:state] == second_state }
    return nil unless from && to

    ((to[:at] - from[:at]) * 1000).round
  end
end
