# spec/services/agents/instantiate_template_spec.rb

# Phase 5b — Template materialization. Explore must write exactly one agent per
# organization per template, never anything invented by a caller, and must
# survive the race where two "Start chat" clicks hit the unique index at once.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock

require "rails_helper"

RSpec.describe Agents::InstantiateTemplate, type: :service do
  let(:organization) { create(:organization) }

  it "materializes a template as a real active agent in the organization" do
    agent = described_class.call(slug: "research-assistant", organization: organization)

    expect(agent).to be_persisted
    expect(agent.organization).to eq(organization)
    expect([ agent.name, agent.slug, agent.provider, agent.model ]).to eq(
      [ "Research Assistant", "research-assistant", "anthropic", "claude-sonnet-4-6" ]
    )
    expect(agent.tools).to eq([ "web_search" ])
    expect(agent.system_prompt).to include("rigorous research assistant")
    expect(agent.config).to eq({ "temperature" => 0.5, "max_tokens" => 4096 })
    expect(agent.is_active).to be(true)
  end

  it "is idempotent within the organization" do
    first = described_class.call(slug: "code-writer", organization: organization)

    expect { described_class.call(slug: "code-writer", organization: organization) }
      .not_to change(Agent, :count)
    repeated = described_class.call(slug: "code-writer", organization: organization)
    expect(repeated.id).to eq(first.id)
    expect(organization.agents.where(slug: "code-writer").count).to eq(1)
  end

  it "keeps organizations separate" do
    other = create(:organization)
    mine = described_class.call(slug: "email-drafter", organization: organization)
    theirs = described_class.call(slug: "email-drafter", organization: other)

    expect(theirs.id).not_to eq(mine.id)
    expect(theirs.organization).to eq(other)
    expect(organization.agents.pluck(:slug)).to eq([ "email-drafter" ])
  end

  it "reuses a pre-existing agent that already owns the slug" do
    existing = create(:agent, organization: organization, name: "My Research Bot", slug: "research-assistant")

    expect(described_class.call(slug: "research-assistant", organization: organization).id).to eq(existing.id)
    expect(existing.reload.name).to eq("My Research Bot")
  end

  it "recovers when a concurrent insert wins the unique index" do
    existing = described_class.call(slug: "task-planner", organization: organization)
    relation = organization.agents
    allow(organization).to receive(:agents).and_return(relation)
    allow(relation).to receive_messages(find_by: nil, find_by!: existing)
    allow(Agents::Templates).to receive(:to_agent).and_raise(ActiveRecord::RecordNotUnique)

    expect(described_class.call(slug: "task-planner", organization: organization)).to eq(existing)
    expect(Agents::Templates).to have_received(:to_agent)
  end

  it "refuses unknown or blank slugs without creating anything" do
    expect { described_class.call(slug: "not-a-template", organization: organization) }
      .to raise_error(ActiveRecord::RecordNotFound, /not-a-template/)
    expect { described_class.call(slug: nil, organization: organization) }
      .to raise_error(ActiveRecord::RecordNotFound)

    expect(Agent.count).to eq(0)
  end
end
