# frozen_string_literal: true

# Phase 4d — Agent form tools picker HTTP contract. The edit form surfaces
# plugin tools only for the organization's connected + active catalog rows,
# and submits them on their own param key (agent[plugin_tools][]) so plain
# built-ins never need fragile paired Rack inputs. The controller merges
# both streams into Agent.tools, pinning each plugin entry to the org's
# active integration row and dropping anything the catalog does not know.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe "Agent tools picker", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization) }
  let(:agent) { create(:agent, organization: organization, tools: [ "calculator", "time" ]) }

  before do
    create(:membership, user: user, organization: organization)
    api_login(user)
  end

  def checkbox_values(body, name)
    Nokogiri::HTML(body).css(%(input[name="#{name}"])).map { |input| input["value"] }
  end

  describe "GET /agents/:id/edit" do
    it "lists plugin tools once the provider is connected and active" do
      create(:tool_integration, organization: organization, provider: "slack")

      get edit_agent_path(agent)
      expect(response).to have_http_status(:ok)
      expect(checkbox_values(response.body, "agent[plugin_tools][]")).to include("slack.post_message")
      expect(response.body).to include("Send a message to a Slack channel.")
    end

    it "hides plugin tools while the integration is paused" do
      create(:tool_integration, organization: organization, provider: "slack", is_active: false)

      get edit_agent_path(agent)
      expect(checkbox_values(response.body, "agent[plugin_tools][]")).to eq([])
      expect(response.body).to include("No connected plugin currently exposes agent tools")
    end

    it "pre-checks the box for an already-selected plugin entry" do
      slack = create(:tool_integration, organization: organization, provider: "slack")
      agent.update!(tools: [ "calculator", { "name" => "slack.post_message", "integration_id" => slack.id } ])

      get edit_agent_path(agent)
      box = Nokogiri::HTML(response.body).at_css("input[value='slack.post_message']")
      expect(box).not_to be_nil
      expect(box["checked"]).to eq("checked")
    end

    it "keeps rendering plain built-in tools untouched" do
      get edit_agent_path(agent)
      values = checkbox_values(response.body, "agent[tools][]")
      expect(values).to include("calculator", "time")
    end
  end

  describe "PATCH /agents/:id with the marketplace picker" do
    let!(:slack) { create(:tool_integration, organization: organization, provider: "slack") }

    it "persists plain strings plus a bound plugin entry" do
      patch agent_path(agent), params: {
        agent: {
          tools: [ "", "calculator" ],
          plugin_tools: [ "", "slack.post_message" ]
        }
      }, headers: api_headers

      expect(response).to have_http_status(:redirect)
      expect(agent.reload.tools).to include("calculator")
      expect(agent.tools).to include({ "name" => "slack.post_message", "integration_id" => slack.id })
      expect(agent.tools.count { |t| t.is_a?(Hash) && t["name"] == "slack.post_message" }).to eq(1)
    end

    it "sends the same name twice without duplicating it" do
      patch agent_path(agent), params: {
        agent: {
          tools: [ "", "calculator", "slack.post_message" ],
          plugin_tools: [ "", "slack.post_message" ]
        }
      }, headers: api_headers

      # The bound hash form wins over the bare string.
      expect(agent.reload.tools).to include({ "name" => "slack.post_message", "integration_id" => slack.id })
      expect(agent.tools).not_to include("slack.post_message")
    end

    it "clears everything when only the sentinels are submitted" do
      patch agent_path(agent), params: {
        agent: { tools: [ "" ], plugin_tools: [ "" ] }
      }, headers: api_headers

      expect(agent.reload.tools).to eq([])
    end

    it "leaves tools untouched when neither key is present" do
      original = agent.tools
      patch agent_path(agent), params: { agent: { description: "Just text" } }, headers: api_headers

      expect(agent.reload.tools).to eq(original)
    end

    it "drops unknown dotted names from tools[] and non-catalog plugin entries" do
      patch agent_path(agent), params: {
        agent: {
          tools: [ "", "calculator", "evil.do_this" ],
          plugin_tools: [ "", "slack.not_a_tool", "slack.post_message" ]
        }
      }, headers: api_headers

      names = agent.reload.tools.map { |t| t.is_a?(Hash) ? t["name"] : t }
      expect(names).to contain_exactly("calculator", "slack.post_message")
    end

    it "still stores a catalog name without a binding when nothing is active" do
      slack.update!(is_active: false)

      patch agent_path(agent), params: {
        agent: { plugin_tools: [ "", "slack.post_message" ] }
      }, headers: api_headers

      expect(agent.reload.tools).to eq([ { "name" => "slack.post_message" } ])
    end

    it "rebinds against the integration rows active at save time" do
      patch agent_path(agent), params: {
        agent: { tools: [ "calculator" ], plugin_tools: [ "slack.post_message" ] }
      }, headers: api_headers
      expect(agent.reload.tools).to include({ "name" => "slack.post_message", "integration_id" => slack.id })

      slack.update!(is_active: false)
      patch agent_path(agent), params: {
        agent: { tools: [ "calculator" ], plugin_tools: [ "slack.post_message" ] }
      }, headers: api_headers
      expect(agent.reload.tools).to eq([ "calculator", { "name" => "slack.post_message" } ])
    end
  end

  describe "create path uses the same sanitizer" do
    it "stores a bound plugin entry on POST /agents" do
      github = create(:tool_integration, organization: organization, provider: "github")
      slug = "triager-#{SecureRandom.hex(4)}"

      post agents_path, params: {
        agent: {
          name: "Triager #{slug}", slug: slug,
          model: "claude-sonnet-4-6", provider: "anthropic",
          tools: [ "", "time" ], plugin_tools: [ "", "github.list_issues" ]
        }
      }, headers: api_headers

      created = Agent.find_by!(slug: slug)
      expect(created.tools).to include("time")
      expect(created.tools).to include({ "name" => "github.list_issues", "integration_id" => github.id })
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
