# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations

require "rails_helper"

# Provider/model pairing helpers behind the agent form's selects.
#
# Both selects used to render Agent::MODELS.values.flatten, so a form could save
# provider=google with a claude model id - a pair no provider serves, which only
# failed later as an upstream 404. These examples lock the scoped option lists,
# including the rule that an already-saved model the catalog no longer offers
# (a local Ollama tag, an openrouter.ai id) stays selectable instead of being
# silently rewritten on the next save.
RSpec.describe Agent do
  describe ".models_for" do
    it "returns exactly the catalog of the requested provider" do
      expect(described_class.models_for("google")).to eq(Agent::MODELS[:google])
      expect(described_class.models_for(:bonsai)).to eq(Agent::MODELS[:bonsai])
    end

    it "falls back to the first catalog when the provider is blank or unknown" do
      # A Model select must never render empty: an option-less select submits a
      # blank model and the record fails presence validation instead.
      expect(described_class.models_for(nil)).to eq(Agent::MODELS.values.first)
      expect(described_class.models_for("not-a-provider")).to eq(Agent::MODELS.values.first)
    end

    it "covers every provider the enum can store" do
      # The form builds its Provider list from MODELS.keys; this keeps the enum
      # and the catalog from drifting apart again.
      expect(described_class.providers.values - described_class::MODELS.keys.map(&:to_s)).to be_empty
    end
  end

  describe "#model_select_options" do
    it "offers only the selected provider's models, as label/value pairs" do
      agent = described_class.new(provider: "anthropic", model: "claude-sonnet-4-6")
      values = agent.model_select_options.map(&:last)

      expect(values).to eq(Agent::MODELS[:anthropic])
      expect(agent.model_select_options).to include([ "claude-sonnet-4-6", "claude-sonnet-4-6" ])
      expect(values).not_to include("gemini-3.6-flash")
    end

    it "keeps a saved model the catalog does not list, marked as such" do
      agent = described_class.new(provider: "ollama", model: "local")
      options = agent.model_select_options

      expect(options.map(&:last)).to include("local")
      expect(options).to include([ "local (saved here)", "local" ])
      # The provider's own catalog still leads the list.
      expect(options.first).to eq([ "llama3.1", "llama3.1" ])
    end

    it "labels the saved value for a google agent holding a foreign model id" do
      agent = described_class.new(provider: "google", model: "claude-sonnet-4-6")
      options = agent.model_select_options

      expect(options.map(&:last)).to eq(Agent::MODELS[:google] + [ "claude-sonnet-4-6" ])
      expect(options.last).to eq([ "claude-sonnet-4-6 (saved here)", "claude-sonnet-4-6" ])
    end

    it "does not duplicate a model that is already in the provider catalog" do
      agent = described_class.new(provider: "google", model: "gemini-2.5-flash")

      expect(agent.model_select_options.map(&:last).tally.values.max).to eq(1)
    end
  end
end
