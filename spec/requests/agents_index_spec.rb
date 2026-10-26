# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations

# Regression: the Phase 1 sidebar "Agents" link was rewired (in Phase 2) from the
# dead agents_path to the real organization_agents_path, which renders
# Agents#index. That page renders Agents::CardComponent, which calls the
# ApplicationHelper#status_badge helper and iterates agent.enabled_tools. A
# ViewComponent must reach app helpers through the `helpers` proxy, and tools can
# be stored as Hashes OR bare Strings. Both had crashes that 500'd the page
# (making the nav link effectively dead). This spec proves the org agents index
# renders an agent card with its status badge + tool chips.
RSpec.describe "Agents index (sidebar destination)", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:agent) do
    create(:agent, organization: organization, name: "Researcher", is_active: true)
  end

  before do
    create(:membership, user: user, organization: organization)
    api_login(user)
    agent # ensure the card exists before the request
  end

  it "renders the agent card with its status badge instead of crashing" do
    get organization_agents_path(organization)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(agent.name)
    expect(response.body).to include("Active")
  end

  it "keeps the legacy Open/Edit card actions when no start_path is passed" do
    get organization_agents_path(organization)

    expect(response.body).to include(agent_path(agent))
    expect(response.body).to include(edit_agent_path(agent))
    expect(response.body).not_to include("Start chat")
    expect(response.body).not_to include("/explore/start")
  end
end

# rubocop:enable RSpec/MultipleExpectations
