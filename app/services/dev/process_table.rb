# app/services/dev/process_table.rb
#
# The process table, in the terms an operating system scheduler uses: one row
# per run, showing how long it waited to be picked up, how long it spent inside
# its own code, how long it spent waiting on the model or a tool, how many times
# it handed the processor over, and how it exited.
#
# Every number is read from `Run#pcb_summary`, i.e. from the transitions that
# were actually recorded while the run was alive (see Run::PCB_STATES). The
# table therefore cannot drift from what was measured, and it says so plainly
# for rows written before the instrumentation existed instead of showing zeros
# that would read like a very fast run.
module Dev
  class ProcessTable
    # One line of the table. `pid` is the run id, `command` is the turn it was
    # asked to answer, `state` is the last transition recorded — so a run whose
    # worker was killed mid-flight stays RUNNING forever, exactly like a real
    # orphaned process, and that is visible rather than smoothed over.
    Row = Struct.new(
      :pid, :command, :run, :status, :state, :waiting_on, :arrival_at, :started_at,
      :finished_at, :queue_ms, :cpu_ms, :io_ms, :bursts, :context_switches,
      :turnaround_ms, :exit_note, :blocked_by, :measured,
      keyword_init: true
    ) do
      def measured?
        !!measured
      end

      def live?
        measured? && state != "exited"
      end

      # Percentage of the measured life of this run that was spent waiting on
      # something outside itself. nil (shown as "—") when nothing was measured,
      # never 0%, which would claim an untracked row was pure CPU.
      def io_share
        return nil unless cpu_ms && io_ms

        total = cpu_ms + io_ms
        return nil if total.zero?

        ((io_ms.to_f / total) * 100).round
      end
    end

    class << self
      def build(runs)
        new(runs.map { |run| row_for(run) })
      end

      def row_for(run)
        query = run.input.is_a?(Hash) ? run.input["query"].to_s : ""
        base = {
          pid: run.id.to_s[0, 8],
          command: query.presence || "(no input recorded)",
          run: run,
          status: run.status,
          started_at: run.started_at,
          finished_at: run.finished_at
        }
        summary = run.pcb_summary
        return Row.new(**base.merge(state: nil, measured: false)) unless summary["recorded"]

        Row.new(
          **base.merge(
            state: summary["current_state"],
            waiting_on: summary["current_note"],
            arrival_at: summary["arrival_at"],
            queue_ms: summary["queue_ms"],
            cpu_ms: summary["cpu_ms"],
            io_ms: summary["io_ms"],
            bursts: summary["bursts"],
            context_switches: summary["context_switches"],
            turnaround_ms: summary["turnaround_ms"],
            exit_note: summary["exit_note"],
            blocked_by: summary["blocked_by"].to_h,
            measured: true
          )
        )
      end
    end

    attr_reader :rows

    def initialize(rows)
      @rows = rows
    end

    # Live processes are the only reason to keep re-fetching this page: once
    # every row has exited the table is history and stops changing.
    def live?
      rows.any?(&:live?)
    end

    def counts
      {
        processes: rows.size,
        live: rows.count(&:live?),
        running: rows.count { |row| row.state == "running" },
        blocked: rows.count { |row| row.state == "blocked" },
        exited: rows.count { |row| row.state == "exited" },
        failed: rows.count { |row| row.measured? && row.exit_note.to_s.start_with?("failed") },
        untracked: rows.count { |row| !row.measured? }
      }
    end

    # Scheduler-level averages, over the rows that were actually measured.
    def averages
      finished = rows.select { |row| row.measured? && row.turnaround_ms }
      measured = rows.select(&:measured?)
      {
        turnaround_ms: mean(finished.map(&:turnaround_ms)),
        queue_ms: mean(measured.map(&:queue_ms).compact),
        cpu_ms: mean(measured.map(&:cpu_ms).compact),
        io_ms: mean(measured.map(&:io_ms).compact)
      }
    end

    # Which resource the box spent its wall time waiting on, summed across the
    # whole table — the number that answers "is the model slow, or are the
    # tools?" without reading a single log line.
    def by_resource
      totals = {}
      rows.each do |row|
        next unless row.measured?

        row.blocked_by.to_a.each do |note, ms|
          totals[note] = totals[note].to_i + ms
        end
      end
      totals.sort_by { |_note, ms| -ms }.to_h
    end

    private

    def mean(values)
      return nil if values.empty?

      (values.sum.to_f / values.size).round
    end
  end
end
