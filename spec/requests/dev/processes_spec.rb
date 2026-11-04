# spec/requests/dev/processes_spec.rb
#
# The dev-only process table over HTTP. Two things have to be true at once: it
# must actually render the transitions each run recorded while it was alive
# (arrival, queue wait, CPU burst, I/O wait, context switches, exit status), and
# it must be unreachable everywhere else. The route is not drawn outside
# Rails.env.local?, and the controller re-checks — this spec proves the guard,
# not only the drawing.
#
# Durations are asserted from explicit `at:` stamps (halves and quarters of a
# second, exact in binary), never from the wall clock: `finish!`/`fail!` stamp
# their exit transition with `Time.current`, so a spec that measured through
# them would be timing the CI box.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "Dev process table", type: :request do
  let(:user) { create(:user) }
  let(:t0) { Time.utc(2026, 11, 4, 17, 53, 20) }

  # Every transition of a finished turn, recorded at a chosen offset from t0.
  def pcb_run(query:, offsets:, status: "succeeded", exit_note: nil)
    create(:run, status: status, input: { "query" => query },
           metadata: Run.seed_pcb_metadata(
             arrival_at: t0, dispatched_at: t0 + 0.5, started_at: t0 + 1
           )).tap do |run|
      offsets.each { |seconds, (state, note)| run.record_state!(state, note: note, at: t0 + seconds) }
      run.record_state!("exited", note: exit_note, at: t0 + (offsets.keys.max + 1)) if exit_note
    end
  end

  def exited_run(query: "Rewrite the importer")
    pcb_run(query: query,
            exit_note: "completed",
            offsets: { 2 => ["blocked", "tool:calculator"], 3 => ["running", "iteration 2"] })
  end

  def blocked_run(query: "Add a checkout page")
    pcb_run(query: query, status: "running",
            offsets: { 2 => ["blocked", "provider:anthropic/claude-sonnet-4-6"] })
  end

  describe "access" do
    it "sends an anonymous visitor to the login page" do
      get "/dev/processes"

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(login_path)
    end

    it "is not reachable when the box is not local" do
      api_login(user)
      allow(Rails.env).to receive(:local?).and_return(false)

      get "/dev/processes"

      expect(response).to have_http_status(:not_found)
    end

    it "renders for a signed-in user on a local box" do
      api_login(user)
      get "/dev/processes"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Process table")
    end
  end

  describe "GET /dev/processes" do
    before { api_login(user) }

    it "renders each run as a process row with its recorded timings" do
      run = exited_run(query: "Rewrite the importer")
      get "/dev/processes"

      body = response.body
      expect(response).to have_http_status(:ok)
      expect(body).to include(run.id.to_s[0, 8])
      expect(body).to include("Rewrite the importer")
      # STATE chip plus the QUEUE / CPU / I/O / TURNAROUND columns.
      expect(body).to include("exited")
      expect(body).to include("500ms")   # queue wait: new → ready
      expect(body).to include("2.0s")    # cpu:  the two running bursts
      expect(body).to include("1.0s")    # i/o:  blocked on tool:calculator
      expect(body).to include("4.0s")    # turnaround: arrival → exit
      expect(body).to include("tool:calculator")
      expect(body).to include("completed")
    end

    it "shows the state a live process is really in and keeps polling for it" do
      run = blocked_run(query: "Add a checkout page")
      get "/dev/processes"

      body = response.body
      expect(body).to include(run.id.to_s[0, 8])
      expect(body).to include("blocked")
      expect(body).to include("provider:anthropic/claude-sonnet-4-6")
      # A process that has not exited is the only reason to re-fetch; the
      # Stimulus controller reads its marching orders from this attribute.
      expect(body).to include('data-controller="refresh-interval"')
      expect(body).to include('data-refresh-interval-live-value="true"')
      expect(body).to include("refreshing while a run is live")
    end

    it "stops polling once every process has exited" do
      exited_run
      get "/dev/processes"

      expect(response.body).to include('data-refresh-interval-live-value="false"')
      expect(response.body).to include("no live runs")
    end

    it "counts a live process by its current state, in words" do
      blocked_run(query: "one")
      exited_run(query: "two")
      get "/dev/processes"

      expect(response.body).to match(/Blocked<\/p>\s*<p[^>]*>1</)
      expect(response.body).to match(/Live<\/p>\s*<p[^>]*>1</)
      expect(response.body).to match(/Exited<\/p>\s*<p[^>]*>1</)
    end

    it "calls a pre-instrumentation row untracked instead of presenting it as instant" do
      create(:run, status: "succeeded", input: { "query" => "Written before the PCB existed" },
             metadata: {})
      get "/dev/processes"

      body = response.body
      expect(body).to include("Written before the PCB existed")
      expect(body).to include("untracked")
      expect(body).to match(/Untracked<\/p>\s*<p[^>]*>1</)
    end

    it "separates a failed exit from a clean one in words, not only colour" do
      run = create(:run, status: "running", input: { "query" => "Explode" },
                   metadata: Run.seed_pcb_metadata(
                     arrival_at: t0, dispatched_at: t0 + 0.5, started_at: t0 + 1
                   ))
      run.fail!("EOFError")
      get "/dev/processes"

      body = response.body
      expect(body).to include("failed: EOFError")
      expect(body).to include(">failed</span>")
      expect(body).not_to include(">exited</span>")
      expect(run.reload.error_message).to eq("EOFError")
    end

    it "answers the model-or-tool question with a per-resource wait total" do
      # Provider waits only on the first row, tool waits only on the second, so
      # the bar list can only show both if it sums across processes.
      pcb_run(query: "slow model",
              exit_note: "completed",
              offsets: { 2 => ["blocked", "provider:anthropic/claude-sonnet-4-6"],
                        5 => ["running", "iteration 2"] })
      exited_run(query: "slow tool")
      get "/dev/processes"

      body = response.body
      expect(body).to include("Wall time spent blocked")
      expect(body).to include("provider:anthropic/claude-sonnet-4-6")
      expect(body).to include("tool:calculator")
    end

    it "says what to do when there is nothing to watch" do
      get "/dev/processes"

      expect(response.body).to include("No runs yet")
    end

    it "keeps the table bounded rather than loading every run ever made" do
      3.times { |i| exited_run(query: "run #{i}") }

      get "/dev/processes", params: { limit: 2 }

      expect(response.body.scan(/last:border-0 hover:bg-hover/).size).to eq(2)
    end

    it "clamps a crafted limit instead of going to zero or unbounded" do
      exited_run(query: "only one")

      get "/dev/processes", params: { limit: "0" }
      expect(response).to have_http_status(:ok)
      expect(response.body.scan(/last:border-0 hover:bg-hover/).size).to eq(1)

      get "/dev/processes", params: { limit: "not-a-number" }
      expect(response).to have_http_status(:ok)
      expect(response.body.scan(/last:border-0 hover:bg-hover/).size).to eq(1)
    end

    it "links each pid to the run it came from" do
      run = exited_run(query: "Inspect this one")
      get "/dev/processes"

      expect(response.body).to include(
        organization_agent_run_path(run.agent.organization, run.agent, run)
      )
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
