# spec/models/run_spec.rb
#
# The process-control-block bookkeeping a run carries in `metadata["pcb"]`.
# These specs are all about timestamps, so every example drives the clock with
# explicit `at:` stamps rather than the wall clock — a spec that sleeps to prove
# a duration is a spec that fails on a loaded machine. Stamps are halves and
# quarters of a second: those are exact in binary, so the millisecond
# expectations below are arithmetic and not luck.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Run, type: :model do
  let(:t0) { Time.utc(2026, 11, 4, 17, 53, 20) }
  let(:run) { create(:run, metadata: {}) }

  def stamp(seconds)
    t0 + seconds
  end

  # A fresh copy straight from the database, so an example can never pass by
  # reading the in-memory attributes `record_state!` happens to have left there.
  def stored(record = run)
    Run.find(record.id)
  end

  def states(record = run)
    stored(record).metadata.dig("pcb", "states")
  end

  describe "PCB_STATES" do
    it "is the five states a process really moves through" do
      expect(Run::PCB_STATES).to eq(%w[new ready running blocked exited])
    end
  end

  describe ".seed_pcb_metadata" do
    it "carries the history that happened before the row existed" do
      metadata = described_class.seed_pcb_metadata(
        arrival_at: stamp(0), dispatched_at: stamp(0.5), started_at: stamp(0.75)
      )

      recorded = metadata["pcb"]["states"]
      expect(recorded.map { |s| s["state"] }).to eq(%w[new ready running])
      expect(recorded.map { |s| s["at"] }).to eq([
        "2026-11-04T17:53:20.000Z",
        "2026-11-04T17:53:20.500Z",
        "2026-11-04T17:53:20.750Z"
      ])
      expect(metadata["pcb"]["arrival_at"]).to eq("2026-11-04T17:53:20.000Z")
      expect(metadata["pcb"]["dispatched_at"]).to eq("2026-11-04T17:53:20.500Z")
    end

    it "records only what was actually measured" do
      # A runner driven directly (specs, ScheduledTasks::RunJob) has no arrival
      # and no queue: inventing them would fabricate a wait time.
      metadata = described_class.seed_pcb_metadata(
        arrival_at: nil, dispatched_at: nil, started_at: stamp(0)
      )

      expect(metadata["pcb"].keys).to eq([ "states" ])
      expect(metadata["pcb"]["states"].map { |s| s["state"] }).to eq([ "running" ])
    end

    it "keeps metadata the caller already had" do
      metadata = described_class.seed_pcb_metadata(
        arrival_at: nil, dispatched_at: nil, started_at: stamp(0), base: { "source" => "whatsapp" }
      )

      expect(metadata["source"]).to eq("whatsapp")
      expect(metadata["pcb"]["states"].size).to eq(1)
    end

    it "survives being stored as jsonb" do
      created = described_class.create!(
        agent: run.agent,
        input: { query: "hi" },
        status: "running",
        started_at: stamp(0),
        metadata: described_class.seed_pcb_metadata(
          arrival_at: stamp(0), dispatched_at: stamp(0.5), started_at: stamp(0.75)
        )
      )

      expect(states(created).map { |s| s["state"] }).to eq(%w[new ready running])
    end
  end

  describe "#record_state!" do
    it "appends transitions in the order they happened, and persists them" do
      run.record_state!("blocked", note: "provider:anthropic/claude-sonnet-4-6", at: stamp(1))
      run.record_state!("running", note: "iteration 2", at: stamp(2))

      recorded = states
      expect(recorded.map { |s| s["state"] }).to eq(%w[blocked running])
      expect(recorded.first["note"]).to eq("provider:anthropic/claude-sonnet-4-6")
      expect(recorded.first["at"]).to eq("2026-11-04T17:53:21.000Z")
      expect(recorded.last["note"]).to eq("iteration 2")

      timeline = stored.pcb_timeline
      expect(timeline.map { |entry| entry[:state] }).to eq(%w[blocked running])
      expect(timeline.first[:at]).to eq(stamp(1))
    end

    it "leaves the rest of the metadata alone" do
      run.update_column(:metadata, { "trigger" => "regenerate" })
      run.record_state!("running", at: stamp(0))

      fresh = stored
      expect(fresh.metadata["trigger"]).to eq("regenerate")
      expect(states.size).to eq(1)
    end

    it "refuses to invent a state the lifecycle does not have" do
      expect(Rails.logger).to receive(:warn).at_least(:once)
      run.record_state!("sleeping", at: stamp(0))

      expect(states).to eq(nil)
      expect(stored.pcb_timeline).to eq([])
    end

    it "never costs the run over a failed bookkeeping write" do
      # The call sites sit inside the provider/tool path: an instrumentation
      # error surfacing from here would fail a run that was going fine.
      allow(run).to receive(:update_column)
        .and_raise(ActiveRecord::StatementInvalid.new("boom"))

      expect { run.record_state!("blocked", note: "tool:scaffold") }.not_to raise_error

      allow(run).to receive(:update_column).and_call_original
      run.record_state!("running", note: "iteration 3", at: stamp(5))
      expect(states(run).map { |s| s["state"] }).to eq([ "running" ])
    end

    it "does not hop the conversation up the sidebar" do
      conversation = create(:conversation, user: create(:user), agent: run.agent)
      live = create(:run, conversation: conversation, metadata: {})
      # Creating the row legitimately touches the conversation; the point is
      # that a state append afterwards does not.
      before = conversation.reload.updated_at

      live.record_state!("blocked", note: "provider:anthropic", at: stamp(0))

      expect(conversation.reload.updated_at).to eq(before)
    end
  end

  describe "exit transitions" do
    let(:run) { create(:run, :running) }

    it "marks EXITED completed when the answer lands" do
      run.finish!(output: "done", tokens_used: 3)

      summary = stored.pcb_summary
      expect(summary["current_state"]).to eq("exited")
      expect(summary["exit_note"]).to eq("completed")
      expect(stored.status).to eq("succeeded")
    end

    it "marks EXITED with the reason it actually failed for" do
      run.fail!(RuntimeError.new("provider socket closed"))

      expect(stored.pcb_summary["exit_note"]).to eq("failed: provider socket closed")
    end

    it "names the cap when the loop ran out of iterations" do
      # The run row itself is written as succeeded, so the note is the only
      # place the truth that the budget ran out survives.
      run.finish!(output: "partial", tokens_used: 1, exit_note: "exited the loop at the iteration cap (20)")

      expect(stored.pcb_summary["exit_note"]).to eq("exited the loop at the iteration cap (20)")
    end

    it "marks EXITED cancelled" do
      run.cancel!

      expect(stored.pcb_summary["exit_note"]).to eq("cancelled")
    end
  end

  describe "#pcb_summary" do
    # A run whose numbers are known in advance:
    #
    #   new ─500ms─> ready ─250ms─> running ─1000ms blocked (provider)─>
    #   running ─500ms─> blocked (tool) ─500ms─> running ─1000ms─> exited
    let(:traced) { create(:run, metadata: {}) }

    before do
      traced.record_state!("new", at: stamp(0))
      traced.record_state!("ready", at: stamp(0.5))
      traced.record_state!("running", at: stamp(0.75))
      traced.record_state!("blocked", note: "provider:anthropic/claude-sonnet-4-6", at: stamp(1.75))
      traced.record_state!("running", note: "iteration 1", at: stamp(2.75))
      traced.record_state!("blocked", note: "tool:calculator", at: stamp(3.25))
      traced.record_state!("running", note: "iteration 1", at: stamp(3.75))
      traced.record_state!("exited", note: "completed", at: stamp(4.75))
    end

    it "reports the queue wait and the time to first work" do
      summary = stored(traced).pcb_summary

      expect(summary["queue_ms"]).to eq(500)
      expect(summary["start_ms"]).to eq(750)
      expect(summary["turnaround_ms"]).to eq(4750)
      expect(summary["arrival_at"]).to eq(stamp(0))
      expect(summary["exited_at"]).to eq(stamp(4.75))
    end

    it "splits the life of the run into CPU bursts and I/O wait" do
      summary = stored(traced).pcb_summary

      # RUNNING intervals: 1000 + 500 + 1000. BLOCKED intervals: 1000 + 500.
      expect(summary["cpu_ms"]).to eq(2500)
      expect(summary["io_ms"]).to eq(1500)
      expect(summary["bursts"]).to eq(3)
      expect(summary["context_switches"]).to eq(5)
      expect(summary["states"]).to eq(8)
    end

    it "says which resource the run was waiting on" do
      expect(stored(traced).pcb_summary["blocked_by"]).to eq(
        "provider:anthropic/claude-sonnet-4-6" => 1000,
        "tool:calculator" => 500
      )
    end

    it "names the state the run is in now" do
      expect(stored(traced).pcb_summary["current_state"]).to eq("exited")
    end

    it "does not charge a live run for the interval it is still inside" do
      live = create(:run, metadata: {})
      live.record_state!("new", at: stamp(0))
      live.record_state!("running", at: stamp(0.75))
      live.record_state!("blocked", note: "provider:anthropic", at: stamp(1.75))

      # The trailing BLOCKED has no end yet: no invented duration, no turnaround.
      summary = stored(live).pcb_summary
      expect(summary["current_state"]).to eq("blocked")
      expect(summary["current_note"]).to eq("provider:anthropic")
      expect(summary["turnaround_ms"]).to be_nil
      expect(summary["cpu_ms"]).to eq(1000)
      expect(summary["io_ms"]).to eq(0)
    end

    it "says so plainly for rows written before this instrumentation" do
      expect(stored(create(:run, metadata: { "legacy" => true })).pcb_summary).to eq(
        "recorded" => false, "states" => 0
      )
    end
  end
end
