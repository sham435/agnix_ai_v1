# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

RSpec.describe "Run disclosure isolation", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:agent) { create(:agent, organization: organization) }
  let(:own_conversation) { create(:conversation, user: user, agent: agent) }
  let(:foreign_conversation) { create(:conversation, user: other_user, agent: agent) }
  let!(:own_run) do
    create(:run, agent: agent, conversation: own_conversation, status: "succeeded",
      input: { query: "member private query" }, output: { content: "member private output" })
  end
  let!(:foreign_run) do
    create(:run, agent: agent, conversation: foreign_conversation, status: "failed",
      input: { query: "foreign private query" }, output: { content: "foreign private output" },
      error_message: "foreign private error")
  end
  let(:html_headers) { { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" } }

  def json
    JSON.parse(response.body)
  end

  around do |example|
    env_config = Rails.application.env_config
    original = env_config.values_at("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    env_config["action_dispatch.show_exceptions"] = :rescuable
    env_config["action_dispatch.show_detailed_exceptions"] = false
    example.run
  ensure
    env_config["action_dispatch.show_exceptions"], env_config["action_dispatch.show_detailed_exceptions"] = original
  end

  before do
    create(:membership, user: user, organization: organization)
    create(:membership, user: other_user, organization: organization)
  end

  context "when anonymous" do
    it "requires authentication for the web run list" do
      get organization_agent_runs_path(organization, agent)

      expect(response).to redirect_to(login_path)
    end

    it "requires authentication for a web run detail" do
      get organization_agent_run_path(organization, agent, own_run)

      expect(response).to redirect_to(login_path)
    end

    it "requires authentication for the API run detail" do
      get api_v1_run_path(own_run)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context "when signed in" do
    before { api_login(user) }

    describe "web run pages" do
      it "lists only the signed-in user's runs" do
        get organization_agent_runs_path(organization, agent)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("member private query")
        expect(response.body).to include(organization_agent_run_path(organization, agent, own_run))
        expect(response.body).not_to include("foreign private query")
        expect(response.body).not_to include(organization_agent_run_path(organization, agent, foreign_run))
      end

      it "shows the signed-in user's full input and output" do
        get organization_agent_run_path(organization, agent, own_run)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("member private query")
        expect(response.body).to include("member private output")
      end

      it "answers another user's run as not found without disclosing its content" do
        get organization_agent_run_path(organization, agent, foreign_run)

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("foreign private query")
        expect(response.body).not_to include("foreign private output")
        expect(response.body).not_to include("foreign private error")
      end

      it "keeps recent runs on the agent detail page user-scoped" do
        get agent_path(agent)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("member private query")
        expect(response.body).not_to include("foreign private query")
      end

      it "hides orphan runs from both web lists" do
        orphan = create(:run, agent: agent, conversation: nil, input: { query: "orphan private query" })

        get organization_agent_runs_path(organization, agent)
        list_body = response.body
        get agent_path(agent)

        expect(response).to have_http_status(:ok)
        expect(list_body).not_to include("orphan private query")
        expect(response.body).not_to include("orphan private query")
        expect(orphan).to be_persisted
      end

      it "answers an orphan run detail as not found" do
        orphan = create(:run, agent: agent, conversation: nil, input: { query: "orphan private query" })

        get organization_agent_run_path(organization, agent, orphan)

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("orphan private query")
      end
    end

    describe "API run detail" do
      it "returns the signed-in user's run with its existing full payload" do
        get api_v1_run_path(own_run), headers: api_headers

        expect(response).to have_http_status(:ok)
        expect(json).to include(
          "id" => own_run.id,
          "input" => { "query" => "member private query" },
          "output" => { "content" => "member private output" }
        )
      end

      it "answers another user's run as not found without disclosing its content" do
        get api_v1_run_path(foreign_run), headers: api_headers

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("foreign private query")
        expect(response.body).not_to include("foreign private output")
        expect(response.body).not_to include("foreign private error")
      end

      it "does not expose a run outside the active organization" do
        other_organization = create(:organization)
        other_agent = create(:agent, organization: other_organization)
        other_conversation = create(:conversation, user: user, agent: other_agent)
        other_run = create(:run, agent: other_agent, conversation: other_conversation,
          input: { query: "outside organization private query" })

        get api_v1_run_path(other_run), headers: api_headers

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("outside organization private query")
      end

      it "does not expose an orphan run through the organization" do
        orphan = create(:run, agent: agent, conversation: nil, input: { query: "orphan private query" })

        get api_v1_run_path(orphan), headers: api_headers

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("orphan private query")
      end

      it "does not give organization admins a cross-user bypass" do
        user.update!(role: "admin")

        get api_v1_run_path(foreign_run), headers: api_headers

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include("foreign private output")
      end
    end

    describe "agent plan controls" do
      it "refuses to resume another user's plan without queuing work" do
        plan = create(:agent_run, conversation: foreign_conversation)
        allow(AgentStreamJob).to receive(:perform_later)

        post resume_agent_run_path(plan), headers: html_headers

        expect(response).to have_http_status(:not_found)
        expect(AgentStreamJob).not_to have_received(:perform_later)
      end

      it "still resumes the signed-in user's own plan" do
        plan = create(:agent_run, conversation: own_conversation)
        allow(AgentStreamJob).to receive(:perform_later)

        post resume_agent_run_path(plan), headers: html_headers

        expect(response).to redirect_to(own_conversation)
        expect(AgentStreamJob).to have_received(:perform_later).with(hash_including(
          conversation_id: own_conversation.id,
          user_id: user.id,
          resume_agent_run_id: plan.id
        ))
      end

      it "refuses to switch another user's plan mode" do
        plan = create(:agent_run, conversation: foreign_conversation, mode: "auto_plan")

        patch switch_mode_agent_run_path(plan), params: { mode: "auto_build" }, headers: api_headers

        expect(response).to have_http_status(:not_found)
        expect(plan.reload.mode).to eq("auto_plan")
      end

      it "still switches the signed-in user's own plan mode" do
        plan = create(:agent_run, conversation: own_conversation, mode: "auto_plan")

        patch switch_mode_agent_run_path(plan), params: { mode: "auto_build" }, headers: api_headers

        expect(response).to have_http_status(:ok)
        expect(plan.reload.mode).to eq("auto_build")
        expect(own_conversation.reload.mode).to eq("auto_build")
      end
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
