# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

# The header "Interrupt current run" button. It used to mark only plan runs and
# answer the Turbo Stream form with `head :ok`, so during ordinary chat it
# stopped nothing and the tab got no reply to the click at all.

RSpec.describe "Conversation stop", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { organization.owner }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:headers) do
    { "X-CSRF-Token" => api_headers["X-CSRF-Token"],
      "ACCEPT" => "text/vnd.turbo-stream.html, text/html" }
  end
  let(:payloads) do
    collected = []
    allow(ActionCable.server).to receive(:broadcast) { |_stream, payload| collected << payload }
    collected
  end

  before do
    create(:membership, user: user, organization: organization, role: "owner")
    api_login(user)
  end

  describe "POST /conversations/:id/stop" do
    let!(:run) do
      Run.create!(agent: agent, conversation: conversation, status: "running",
        input: { "query" => "hi" }, started_at: Time.current)
    end
    let!(:plan_run) { create(:agent_run, conversation: conversation, status: "executing") }
    let!(:placeholder) do
      conversation.messages.create!(role: "assistant", content: "Half an ",
        metadata: { "streaming" => true, "request_id" => "req-1" })
    end

    it "cancels the chat run and the plan run, and answers the tab" do
      frames = payloads

      post stop_conversation_path(conversation), headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(run.reload.status).to eq("cancelled")
      expect(run.finished_at).to be_present
      expect(plan_run.reload.status).to eq("interrupted")
      expect(response.body).to include("Stopping the current run.")

      stopped = frames.find { |frame| frame[:type] == "stopped" }
      expect(stopped).to be_present
      expect(stopped[:conversation_id]).to eq(conversation.id)
      expect(stopped[:message_id]).to eq(placeholder.id)
      expect(stopped[:request_id]).to eq("req-1")
    end

    it "answers honestly when there is no run to stop" do
      run.cancel!
      plan_run.update!(status: "completed")
      placeholder.update!(metadata: placeholder.metadata.except("streaming"))
      frames = payloads

      post stop_conversation_path(conversation), headers: headers

      expect(response.body).to include("Nothing is running in this conversation.")
      expect(frames).to be_empty
    end

    it "leaves a finalized reply alone and stops only the live placeholder" do
      conversation.messages.create!(role: "assistant", content: "older finished answer")
      frames = payloads

      post stop_conversation_path(conversation), headers: headers

      stopped = frames.find { |frame| frame[:type] == "stopped" }
      expect(stopped[:message_id]).to eq(placeholder.id)
    end
  end

  describe "POST /conversations/:id/interrupt" do
    let!(:run) do
      Run.create!(agent: agent, conversation: conversation, status: "running",
        input: { "query" => "hi" })
    end
    let!(:plan_run) { create(:agent_run, conversation: conversation, status: "planning") }

    it "does the same thing through the route the plan card uses" do
      post interrupt_conversation_path(conversation), headers: headers

      expect(run.reload.status).to eq("cancelled")
      expect(plan_run.reload.status).to eq("interrupted")
      expect(response.body).to include("Stopping the current run.")
    end
  end
end
