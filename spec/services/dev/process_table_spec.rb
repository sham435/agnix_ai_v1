# spec/services/dev/process_table_spec.rb
#
# The process table is a *view* over the transitions each run recorded while it
# was alive, so these specs are really about not inventing anything: an
# unmeasured row must come out empty rather than zero, a live run must not be
# charged for the interval it has not finished, and the wall time spent waiting
# on the model has to be attributable to the model.
#
# Timestamps are halves and quarters of a second — exact in binary — so the
# millisecond assertions below are arithmetic, not luck.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Dev::ProcessTable do
  let(:t0) { Time.utc(2026, 11, 4, 17, 53, 20) }

  def stamp(seconds)
    t0 + seconds
  end

  # A run that arrived at t0, was dispatched half a second later and started a
  # second after that — the three transitions the row is created with. Anything
  # past that is added by the block, through the same API the runner uses.
  def measured(query: "Build me a landing page", status: "succeeded")
    run = create(:run,
                 status: status,
                 input: { "query" => query },
                 metadata: Run.seed_pcb_metadata(
                   arrival_at: stamp(0), dispatched_at: stamp(0.5), started_at: stamp(1)
                 ))
    yield run if block_given?
    run
  end

  def legacy(query: "Legacy")
    create(:run, status: "succeeded", input: { "query" => query }, metadata: {})
  end

  describe "row_for" do
    it "shows the first eight characters of the run id as the pid" do
      run = measured(query: "Rename the shop module")
      row = described_class.row_for(run)

      expect(row.pid).to eq(run.id.to_s[0, 8])
      expect(row.command).to eq("Rename the shop module")
      expect(row.run).to eq(run)
      expect(row.status).to eq("succeeded")
    end

    it "says so when no input was recorded instead of rendering a blank command" do
      row = described_class.row_for(create(:run, input: {}, metadata: {}))

      expect(row.command).to eq("(no input recorded)")
    end

    it "reports the exit note and marks an exited process as finished" do
      run = measured do |r|
        r.record_state!("blocked", note: "provider:anthropic/claude-sonnet-4-6", at: stamp(2))
        r.record_state!("running", note: "iteration 2", at: stamp(3))
        r.record_state!("exited", note: "completed", at: stamp(4))
      end
      row = described_class.row_for(run)

      expect(row.measured?).to be(true)
      expect(row.state).to eq("exited")
      expect(row.exit_note).to eq("completed")
      expect(row.live?).to be(false)
      expect(row.waiting_on).to be_nil
      expect(row.queue_ms).to eq(500)
      expect(row.cpu_ms).to eq(2_000)
      expect(row.io_ms).to eq(1_000)
      expect(row.bursts).to eq(2)
      expect(row.context_switches).to eq(3)
      expect(row.turnaround_ms).to eq(4_000)
      expect(row.io_share).to eq(33)
      expect(row.blocked_by).to eq("provider:anthropic/claude-sonnet-4-6" => 1_000)
    end

    it "leaves a live run's unfinished interval uncounted" do
      run = measured(status: "running") do |r|
        r.record_state!("blocked", note: "tool:calculator", at: stamp(2))
      end
      row = described_class.row_for(run)

      # The blocked transition at t+2 is the newest one; nothing has come after
      # it, so the table cannot claim the run spent any time in that state.
      expect(row.state).to eq("blocked")
      expect(row.waiting_on).to eq("tool:calculator")
      expect(row.live?).to be(true)
      expect(row.turnaround_ms).to be_nil
      expect(row.cpu_ms).to eq(1_000)
      expect(row.io_ms).to eq(0)
      expect(row.io_share).to eq(0)
    end

    it "marks a row from before the instrumentation as untracked" do
      row = described_class.row_for(legacy)

      expect(row.measured?).to be(false)
      expect(row.state).to be_nil
      expect(row.live?).to be(false)
      expect([row.queue_ms, row.cpu_ms, row.io_ms, row.bursts,
              row.context_switches, row.turnaround_ms, row.blocked_by]).to all(be_nil)
      # nil, never 0: 0% would claim this process waited on nothing.
      expect(row.io_share).to be_nil
    end
  end

  describe "counts" do
    it "tallies the table the way ps does, separating failed exits from clean ones" do
      exited = measured { |r| r.record_state!("exited", note: "completed", at: stamp(2)) }
      failed = measured(status: "failed") { |r| r.record_state!("exited", note: "failed: EOFError", at: stamp(2)) }
      blocked = measured(status: "running") { |r| r.record_state!("blocked", note: "provider:ollama/qwen", at: stamp(2)) }
      running = measured(status: "running") { |r| r.record_state!("running", note: "iteration 3", at: stamp(2)) }

      table = described_class.build([exited, failed, blocked, running, legacy])

      expect(table.counts).to eq(
        processes: 5, live: 2, running: 1, blocked: 1,
        exited: 2, failed: 1, untracked: 1
      )
    end

    it "knows when something is still worth re-fetching" do
      exited = measured { |r| r.record_state!("exited", note: "completed", at: stamp(2)) }
      expect(described_class.build([exited]).live?).to be(false)

      alive = measured(status: "running")
      expect(described_class.build([exited, alive]).live?).to be(true)
    end
  end

  describe "averages" do
    it "averages over the measured rows only" do
      one = measured { |r| r.record_state!("exited", note: "completed", at: stamp(3)) }
      two = measured(query: "second") do |r|
        r.record_state!("blocked", note: "provider:x/y", at: stamp(2))
        r.record_state!("exited", note: "completed", at: stamp(4))
      end

      averages = described_class.build([one, two, legacy]).averages

      # one: queue 500, cpu 2000 (running 1→3), io 0, turnaround 3000
      # two: queue 500, cpu 1000 (running 1→2), io 2000 (blocked 2→4), turnaround 4000
      # the legacy row is not in any denominator.
      expect(averages).to eq(
        turnaround_ms: 3_500, queue_ms: 500, cpu_ms: 1_500, io_ms: 1_000
      )
    end

    it "returns nil rather than zero when nothing was measured" do
      expect(described_class.build([legacy]).averages).to eq(
        turnaround_ms: nil, queue_ms: nil, cpu_ms: nil, io_ms: nil
      )
    end
  end

  describe "by_resource" do
    it "sums the wall time spent waiting on each named resource, slowest first" do
      first = measured do |r|
        r.record_state!("blocked", note: "provider:anthropic/claude-sonnet-4-6", at: stamp(2))
        r.record_state!("running", note: "iteration 2", at: stamp(5))
        r.record_state!("blocked", note: "tool:calculator", at: stamp(6))
        r.record_state!("exited", note: "completed", at: stamp(7))
      end
      second = measured(query: "second") do |r|
        r.record_state!("blocked", note: "provider:anthropic/claude-sonnet-4-6", at: stamp(2))
        r.record_state!("exited", note: "completed", at: stamp(4))
      end

      table = described_class.build([first, second, legacy])

      expect(table.by_resource).to eq(
        "provider:anthropic/claude-sonnet-4-6" => 5_000,
        "tool:calculator" => 1_000
      )
    end

    it "is empty when no process ever blocked" do
      run = measured { |r| r.record_state!("exited", note: "completed", at: stamp(2)) }

      expect(described_class.build([run]).by_resource).to eq({})
    end
  end

  describe "ordering" do
    it "keeps the rows in the order the controller asked for" do
      table = described_class.build([measured(query: "newest"), measured(query: "older")])

      expect(table.rows.map(&:command)).to eq(%w[newest older])
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
