# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength

require "rails_helper"

# The agent form and the agent page must offer only models the selected provider
# serves. Both rendered Agent::MODELS.values.flatten before, so a saved pair
# could name a model its provider does not have (provider=google + a claude id),
# which surfaced only as an upstream 404 at run time.
RSpec.describe "Provider-scoped model selects", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization) }

  before do
    create(:membership, user: user, organization: organization)
    api_login(user)
  end

  def model_option_values(body)
    Nokogiri::HTML(body).css("select#agent_model option").map { |option| option["value"] }
  end

  def provider_option_values(body)
    Nokogiri::HTML(body).css("select#agent_provider option").map { |option| option["value"] }
  end

  describe "GET /agents/new" do
    it "scopes the Model select to the record's provider and ships the catalog to Stimulus" do
      get new_agent_path
      body = response.body

      expect(response).to have_http_status(:ok)
      expect(model_option_values(body)).to eq(Agent::MODELS[:anthropic])
      expect(model_option_values(body)).not_to include("gemini-3.6-flash", "llama3.1")

      # The provider list comes from MODELS.keys now, so an enum value without
      # models can never be offered again (that is how google became dead config).
      expect(provider_option_values(body)).to eq(Agent::MODELS.keys.map(&:to_s))

      form = Nokogiri::HTML(body).at_css("form[data-provider-models-models-value]")
      expect(form["data-controller"]).to eq("provider-models")
      expect(JSON.parse(form["data-provider-models-models-value"])).to eq(
        Agent::MODELS.each_with_object({}) { |(key, models), hash| hash[key.to_s] = models }
      )

      # Read attributes through Nokogiri so HTML escaping cannot be mistaken for
      # a regression (ERB writes data-action's ">" as "&gt;").
      provider_select = Nokogiri::HTML(body).at_css("select#agent_provider")
      expect(provider_select["data-provider-models-target"]).to eq("provider")
      expect(provider_select["data-action"]).to eq("change->provider-models#sync")
      expect(Nokogiri::HTML(body).at_css("select#agent_model")["data-provider-models-target"]).to eq("model")
    end

    it "scopes the select to the provider an Explore template prefills" do
      # "arabic-english-translator" is curated as provider=openai, so the form it
      # opens must list gpt ids only - the flat list used to offer claude ids here.
      template = Agents::Templates.find("arabic-english-translator")
      expect(template[:provider]).to eq("openai")

      get new_agent_path(template: template[:slug])
      body = response.body

      expect(model_option_values(body)).to eq(Agent::MODELS[:openai])
      expect(model_option_values(body)).not_to include("claude-sonnet-4-6", "gemini-3.5-flash")
      selected = Nokogiri::HTML(body).css("select#agent_provider option[selected]").map { |o| o["value"] }
      expect(selected).to eq([ "openai" ])
    end
  end

  describe "GET /agents/:id/edit" do
    it "lists only that provider's models for a google agent" do
      agent = create(:agent, organization: organization, provider: "google", model: "gemini-2.5-flash")

      get edit_agent_path(agent)

      expect(model_option_values(response.body)).to eq(Agent::MODELS[:google])
      expect(model_option_values(response.body)).not_to include("claude-sonnet-4-6")
    end

    it "keeps a saved model the catalog does not offer, instead of rewriting it" do
      # ollama/local is a real tag on a local server but not in Agent::MODELS.
      agent = create(:agent, organization: organization, provider: "ollama", model: "local")

      get edit_agent_path(agent)
      values = model_option_values(response.body)

      expect(values).to eq(Agent::MODELS[:ollama] + [ "local" ])
      expect(response.body).to include("local (saved here)")
      expect(Nokogiri::HTML(response.body).at_css('#agent_model option[value="local"]')["selected"]).not_to be_nil
    end
  end

  describe "GET /agents/:id" do
    it "scopes the auto-submitting model switcher to the agent's provider" do
      agent = create(:agent, organization: organization, provider: "google", model: "gemini-3.5-flash")

      get agent_path(agent)

      values = model_option_values(response.body)
      expect(values).to eq(Agent::MODELS[:google])
      # A single stray click must not be able to send another provider's id.
      expect(values).not_to include("claude-sonnet-4-6", "gpt-4o", "llama3.1")

      # And the click must actually save. An inline `onchange=` attribute is dead
      # code here: the script-src nonce in this app's CSP cancels 'unsafe-inline'
      # for event handler attributes, so only a Stimulus action (module code from
      # 'self') ever runs.
      switcher = Nokogiri::HTML(response.body).at_css("select#agent_model")
      expect(switcher["onchange"]).to be_nil
      expect(switcher["data-controller"]).to eq("auto-submit")
      expect(switcher["data-action"]).to eq("change->auto-submit#submit")
    end
  end

  describe "GET /conversations/:id" do
    it "scopes the chat header's model switcher to the conversation agent's provider" do
      # The header patches the agent, so it offers the same list as the agent page.
      # Until now it rendered Agent::MODELS.values.flatten, which let one stray
      # click in the middle of a chat pair a Gemini agent with a claude id.
      agent = create(:agent, organization: organization, provider: "google", model: "gemini-2.5-flash")
      conversation = create(:conversation, user: user, agent: agent)

      get conversation_path(conversation)
      body = response.body

      expect(response).to have_http_status(:ok)
      expect(model_option_values(body)).to eq(Agent::MODELS[:google])
      expect(model_option_values(body)).not_to include("claude-sonnet-4-6", "gpt-4o", "llama3.1")

      # Still a Stimulus action: an inline handler attribute is dead under this
      # app's nonce-bearing script-src, so the switch would have looked saved and
      # not been.
      switcher = Nokogiri::HTML(body).at_css("select#agent_model")
      expect(switcher["onchange"]).to be_nil
      expect(switcher["data-controller"]).to eq("auto-submit")
      expect(switcher["data-action"]).to eq("change->auto-submit#submit")
    end

    it "keeps the model a conversation agent is actually running when the catalog lacks it" do
      # ollama/local is a tag on the user's own server: not in Agent::MODELS, but
      # dropping it from the header list would invite a switch that silently
      # rewrites the working model on the next save.
      agent = create(:agent, organization: organization, provider: "ollama", model: "local")
      conversation = create(:conversation, user: user, agent: agent)

      get conversation_path(conversation)
      body = response.body

      expect(model_option_values(body)).to eq(Agent::MODELS[:ollama] + [ "local" ])
      expect(body).to include("local (saved here)")
      expect(Nokogiri::HTML(body).at_css('#agent_model option[value="local"]')["selected"]).not_to be_nil
    end
  end

  describe "POST /agents" do
    # This app verifies authenticity tokens before controller callbacks, so an
    # unsafe request without api_headers dies at 422 before AgentsController#new.
    it "persists a google agent on a Gemini model" do
      post agents_path, params: {
        agent: { name: "Gemini Runner", provider: "google", model: "gemini-2.5-flash",
                 system_prompt: "Go." }
      }, headers: api_headers

      expect(response).to have_http_status(:redirect)
      agent = Agent.find_by(name: "Gemini Runner")
      expect(agent).to be_persisted
      expect(agent.provider).to eq("google")
      expect(agent.model).to eq("gemini-2.5-flash")
    end

    it "still accepts a provider/model pair outside the catalog" do
      post agents_path, params: {
        agent: { name: "Local Runner", provider: "ollama", model: "local",
                 system_prompt: "Go." }
      }, headers: api_headers

      expect(response).to have_http_status(:redirect)
      expect(Agent.find_by(name: "Local Runner").model).to eq("local")
    end
  end
end
