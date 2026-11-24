# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/AnyInstance

require "rails_helper"

# M14 Issue A — one explicit acceptance walk of the model-selection ladder:
# conversation selection -> org-scoped user preference -> organization default
# -> permitted system fallback -> clear model_required error — plus the
# per-execution capture that freezes the effective model for in-flight requests.
RSpec.describe "LLM model selection precedence" do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:agent) { create(:agent, organization: organization, provider: "anthropic", model: "claude-agent-model", tools: []) }
  let(:conversation) { create(:conversation, user: user, agent: agent, metadata: {}) }
  let(:org_default) { { "provider_id" => "bonsai", "model_id" => "bonsai-2-27b" } }
  let(:user_preference) { { "provider_id" => "anthropic", "model_id" => "preferred-model" } }
  let(:conversation_model) { { "provider_id" => "anthropic", "model_id" => "conversation-model" } }

  def resolver(with_conversation: false)
    Llm::ModelSelection.new(user: user, organization: organization, conversation: with_conversation ? conversation : nil)
  end

  before do
    allow_any_instance_of(Llm::ModelCatalogue).to receive(:resolve!).and_return(true)
  end

  it "honors the ladder without letting an absent conversation selection bypass the user preference or organization default" do
    organization.update!(settings: { "default_model" => org_default })
    expect(resolver.selected).to eq(org_default)

    user.update!(settings: { "preferred_models" => { organization.id.to_s => user_preference } })
    expect(resolver.selected).to eq(user_preference)
    expect(resolver(with_conversation: true).selected).to eq(user_preference)

    conversation.update!(metadata: { "selected_model" => conversation_model })
    expect(resolver(with_conversation: true).selected).to eq(conversation_model)
  end

  it "raises a clear model_required error when no eligible model exists" do
    organization.update!(settings: { "allow_system_model_fallback" => false })
    expect(resolver.selected).to be_nil
    expect(resolver.snapshot).to be_nil
    expect { resolver.snapshot! }.to raise_error(Llm::ModelCatalogue::Error, /Choose a model or configure an organization default/)
  end

  it "uses the permitted system fallback when conversation, user and organization are all unset" do
    ENV["SHAMS_DEFAULT_MODEL_PROVIDER"] = "bonsai"
    ENV["SHAMS_DEFAULT_MODEL_ID"] = "sys-fallback-model"
    organization.update!(settings: { "allow_system_model_fallback" => true })
    expect(resolver.selected).to eq("provider_id" => "bonsai", "model_id" => "sys-fallback-model")
  ensure
    ENV.delete("SHAMS_DEFAULT_MODEL_PROVIDER")
    ENV.delete("SHAMS_DEFAULT_MODEL_ID")
  end

  it "stamps the resolved user preference when a chat starts without a conversation selection" do
    organization.update!(settings: { "default_model" => org_default })
    user.update!(settings: { "preferred_models" => { organization.id.to_s => user_preference } })

    # The test env runs jobs inline; defer the stream hand-off so this stays
    # an assertion about the stamped metadata, not a live provider call.
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    started = Conversations::StartChat.call(user: user, agent: agent, content: "hello")

    expect(started.metadata["selected_model"]).to eq(user_preference)
    expect(started.messages.find_by(role: "user").metadata["selected_model"]).to eq(user_preference)
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  it "captures the effective model per execution so later configuration changes cannot alter an in-progress request" do
    create(:tool_integration, organization: organization, provider: "anthropic", credentials: { "api_key" => "in-flight-key" })
    source = conversation.messages.create!(role: "user", content: "go",
                                          metadata: { "selected_model" => conversation_model })

    # Configuration mutates after the message was enqueued.
    organization.update!(settings: { "default_model" => { "provider_id" => "bonsai", "model_id" => "changed-later" } })
    conversation.update!(metadata: { "selected_model" => org_default })

    runner = AgentRunner.new(agent: agent, conversation: conversation, user: user, source_message: source)
    expect(runner.send(:build_client_for_agent)).to have_attributes(provider: "anthropic", model: "conversation-model")
    expect([ runner.send(:effective_provider), runner.send(:effective_model) ]).to eq([ "anthropic", "conversation-model" ])

    # A brand-new execution after the change resolves the new configuration.
    expect(resolver(with_conversation: true).selected).to eq(org_default)
  end

  it "keeps the agent-configured model as the runner baseline when nothing is selected" do
    organization.update!(settings: {})
    runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
    expect(runner.send(:build_client_for_agent)).to have_attributes(provider: "anthropic", model: "claude-agent-model")
    expect([ runner.send(:effective_provider), runner.send(:effective_model) ]).to eq([ "anthropic", "claude-agent-model" ])
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/AnyInstance
