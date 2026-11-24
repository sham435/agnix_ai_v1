# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Conversation background tasks", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { organization.owner }
  let(:other_user) { create(:user) }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent, title: "Task conversation") }

  before do
    create(:membership, user: user, organization: organization, role: "owner")
    allow(AgentStreamJob).to receive(:perform_later)
  end

  it "requires authentication" do
    get tasks_conversation_path(conversation), as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not expose another user's task state" do
    api_login(other_user)

    get tasks_conversation_path(conversation), as: :json

    expect(response).to have_http_status(:not_found)
  end

  it "returns real active and queued tasks without double-counting the streaming placeholder" do
    api_login(user)
    initial = Conversations::TurnAdmission.call(conversation: conversation, user: user,
      params: { content: "Start", client_request_id: "active-request" })
    create(:run, :running, agent: agent, conversation: conversation,
      metadata: { "request_id" => initial.request_id })
    placeholder = conversation.messages.where(role: "assistant").order(:created_at).last
    Conversations::TurnAdmission.call(conversation: conversation, user: user,
      params: { content: "Follow up", client_request_id: "follow-up" })
    Conversations::TurnAdmission.call(conversation: conversation, user: user,
      params: { content: "Change approach", client_request_id: "steering" }, requested_mode: "steer")

    get tasks_conversation_path(conversation), as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to include("active" => 1, "queued" => 2, "active_request_id" => "active-request")
    expect(body["tasks"].map { |task| task["id"] }).not_to include("message-#{placeholder.id}")
    run_task = body["tasks"].find { |task| task["kind"] == "run" }
    expect(run_task).to include("state" => "running", "conversation_title" => "Task conversation", "agent_name" => agent.name)
    expect(run_task["actions"]).to include("stop", "view")
    expect(run_task["path"]).to eq(organization_agent_run_path(organization, agent, Run.last))
    expect(body["tasks"].select { |task| task["state"] == "queued" }.map { |task| task["preview"] })
      .to eq([ "Follow up", "Change approach" ])
  end

  it "reports a manual plan as waiting for user input" do
    api_login(user)
    plan = create(:agent_run, conversation: conversation, mode: "manual_plan", status: "planning")

    get tasks_conversation_path(conversation), as: :json

    body = JSON.parse(response.body)
    expect(body).to include("active" => 1, "queued" => 0)
    expect(body["tasks"].find { |task| task["id"] == plan.id }).to include(
      "state" => "waiting_for_user", "terminal_status" => nil, "actions" => [ "stop", "approve_plan" ]
    )
  end

  it "includes recent terminal tasks with their final states" do
    api_login(user)
    run = create(:run, agent: agent, conversation: conversation, status: "succeeded",
      started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    plan = create(:agent_run, conversation: conversation, status: "interrupted")

    get tasks_conversation_path(conversation), as: :json

    body = JSON.parse(response.body)
    expect(body).to include("active" => 0, "queued" => 0)
    expect(body["tasks"].find { |task| task["id"] == run.id }).to include(
      "state" => "completed", "terminal_status" => "completed", "actions" => [ "view" ]
    )
    expect(body["tasks"].find { |task| task["id"] == plan.id }).to include(
      "state" => "cancelled", "terminal_status" => "cancelled", "actions" => []
    )
  end

  it "renders the accessible task surface on first paint" do
    api_login(user)
    create(:run, :running, agent: agent, conversation: conversation)

    get conversation_path(conversation)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-chat-input-target="taskPanel"')
    expect(response.body).to include('data-chat-input-target="taskCount"')
    expect(response.body).to include('data-chat-input-target="taskList"')
    expect(response.body).to include("Agent response")
    expect(response.body).to include("Running")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
