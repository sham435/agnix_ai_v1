# frozen_string_literal: true

# Phase 4d — Per-message tool selection HTTP contract. The composer's Tools
# dropdown submits native message[tools][] checkboxes with each send; the
# controller records the sanitized subset in Message metadata under "tools".
# Absent/blank selections leave the key off entirely, which the runner reads
# as "use the agent's configured tools". AgentRunner's narrowing behavior is
# covered in spec/services/agent_runner_plugins_spec.rb; this file proves the
# wire format and that the composer lists exactly the runnable tools.
# rubocop:disable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "Per-message tool selection", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization) }
  let(:agent) { create(:agent, organization: organization, tools: [ "calculator", "time" ]) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    create(:membership, user: user, organization: organization)
    allow(AgentStreamJob).to receive(:perform_later).and_return(true)
    api_login(user)
  end

  def post_message(tools: nil, extra: {})
    message_params = { content: "Run with my tools" }
    message_params[:tools] = tools if tools
    post conversation_messages_path(conversation),
         params: { message: message_params.merge(extra) },
         headers: api_headers
  end

  def last_message
    conversation.messages.order(:created_at).last
  end

  describe "POST /conversations/:id/messages" do
    it "records the chosen subset in metadata, dropping blanks and duplicates" do
      post_message(tools: [ "calculator", "", "calculator", "time" ])

      expect(response.status).to be_in([ 200, 201, 302, 303 ])
      expect(last_message.metadata["tools"]).to eq([ "calculator", "time" ])
    end

    it "omits the metadata key when no selection is sent" do
      post_message

      expect(last_message.metadata).not_to have_key("tools")
    end

    it "omits the key when every checkbox is blank (agent default)" do
      post_message(tools: [ "", " " ])

      expect(last_message.metadata).not_to have_key("tools")
    end

    it "coexists with the client_request_id stamp" do
      cid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      post_message(tools: [ "time" ], extra: { client_request_id: cid })

      expect(last_message.metadata).to include("tools" => [ "time" ], "client_request_id" => cid)
    end

    it "stores plugin names verbatim so the runner can intersect them" do
      post_message(tools: [ "slack.post_message" ])

      expect(last_message.metadata["tools"]).to eq([ "slack.post_message" ])
    end
  end

  describe "composer dropdown on GET /conversations/:id" do
    it "lists plain agent tools as checkboxes" do
      get conversation_path(conversation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(name="message[tools][]" value="calculator"))
      expect(response.body).to include(%(name="message[tools][]" value="time"))
      expect(response.body).to include("All unchecked = the agent")
    end

    it "lists a plugin tool only while its integration stays connected and active" do
      agent.update!(tools: [ "calculator", { "name" => "slack.post_message", "integration_id" => nil } ])
      slack = create(:tool_integration, organization: organization, provider: "slack")

      get conversation_path(conversation)
      expect(response.body).to include(%(name="message[tools][]" value="slack.post_message"))

      slack.update!(is_active: false)
      get conversation_path(conversation)
      expect(response.body).not_to include(%(name="message[tools][]" value="slack.post_message"))
      expect(response.body).to include(%(name="message[tools][]" value="calculator"))
    end

    it "drops unknown dotted leftovers from the list" do
      agent.update!(tools: [ "calculator", "evil.do_this" ])

      get conversation_path(conversation)
      expect(response.body).not_to include(%(value="evil.do_this"))
      expect(response.body).to include(%(value="calculator"))
    end

    it "renders no dropdown at all for a tool-less agent" do
      agent.update!(tools: [])

      get conversation_path(conversation)
      expect(response.body).not_to include(%(name="message[tools][]"))
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
