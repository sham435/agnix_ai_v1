# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

# Regressions for /agents/:id, which was a guaranteed 500:
#
#   1. NoMethodError: undefined method `organization_agent_test_path' — the
#      nested member route is declared `member { get :test; post :test }`
#      inside `resources :organizations { resources :agents }`, so Rails names
#      the helper test_organization_agent_path (action prefix first).
#   2. TypeError: no implicit conversion of Symbol into Integer — the Tools
#      card indexed every enabled_tools entry with a Symbol, but native tools
#      persist as bare name Strings.
#
# Nothing exercised these views (or the playground page they link to), which is
# how both shipped silently.
RSpec.describe "Agent detail page", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let!(:agent) { create(:agent, organization: organization, name: "Code Writer") }

  before do
    create(:membership, user: user, organization: organization)
    api_login(user)
  end

  it "renders with a working Test link to the playground route" do
    get agent_path(agent)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(test_organization_agent_path(organization, agent))
    expect(response.body).to include(agent.name)
  end

  it "renders tool chips for both persisted tool shapes" do
    # Factory default is bare Strings; configured tools are Hashes.
    get agent_path(agent)
    expect(response.body).to include("calculator")

    agent.update!(tools: [ { "name" => "web_search", "enabled" => true } ])
    get agent_path(agent)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("web_search")
  end

  it "renders the playground page its Test link points at" do
    get test_organization_agent_path(organization, agent)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Test Playground")
    # The form must post to the same member route the page was reached through.
    expect(response.body).to include(%(action="#{test_organization_agent_path(organization, agent)}"))
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
