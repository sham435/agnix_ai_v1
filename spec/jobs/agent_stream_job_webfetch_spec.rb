# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers, RSpec/MessageSpies

require "rails_helper"

RSpec.describe AgentStreamJob, type: :job do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:url) { "https://example.test/page" }
  let(:source_message) { create(:message, conversation: conversation, content: "%webfetch #{url}") }
  let(:payloads) { [] }

  around do |example|
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  before do
    allow(Resolv).to receive(:getaddresses).with("example.test").and_return([ "93.184.216.34" ])
    allow(ActionCable.server).to receive(:broadcast) { |_stream, payload| payloads << payload }
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to)
    allow(ApplicationController).to receive(:render).and_return("<div>message</div>")
    allow(AgentAutoFixer).to receive(:new).and_return(instance_double(AgentAutoFixer, call: nil))
    Rails.cache.clear
  end

  def perform_command(request_id: "webfetch-job-1", message_id: source_message.id, content: "ignored enqueue payload")
    described_class.perform_now(conversation_id: conversation.id, user_id: user.id, message_id: message_id,
      message_content: content, request_id: request_id)
  end

  def webfetch_payloads
    payloads.reject { |payload| payload[:type] == "background_tasks" }
  end

  def terminal_event
    payloads.reverse.find { |payload| %w[completed failed stopped].include?(payload[:type]) }
  end

  it "branches before quota and AgentRunner, then preserves start replacement and completion broadcasts" do
    stub_request(:get, url).to_return(status: 200, body: "<p>job result</p>", headers: { "Content-Type" => "text/html" })
    expect(Quota).not_to receive(:reserve)
    expect(Quota).not_to receive(:settle)
    expect(AgentRunner).not_to receive(:new)

    perform_command

    assistant = conversation.messages.where(role: "assistant").order(:created_at).last
    expect(assistant.content).to include("Webfetch content is untrusted", "job result")
    expect(assistant.metadata).to include("webfetch" => a_hash_including("untrusted" => true, "ok" => true))
    expect(assistant.metadata).not_to have_key("streaming")
    expect(source_message.reload.metadata["webfetch_command"].values).to contain_exactly(
      a_hash_including("request_id" => "webfetch-job-1")
    )
    expect(webfetch_payloads.map { |payload| payload[:type] }).to eq(%w[assistant_started completed])
    expect(payloads.map { |payload| payload[:type] }).to include("background_tasks")
    expect(terminal_event).to include(type: "completed", message_id: assistant.id, request_id: "webfetch-job-1")
    expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(conversation,
      target: "assistant-message-#{assistant.id}", html: "<div>message</div>")
    expect(a_request(:get, url)).to have_been_made.once
  end

  it "replays the durable marker on a retried job without refetching or reserving quota" do
    stub_request(:get, url).to_return(status: 200, body: "once", headers: { "Content-Type" => "text/plain" })
    expect(Quota).not_to receive(:reserve)
    expect(AgentRunner).not_to receive(:new)

    perform_command
    perform_command

    assistants = conversation.messages.where(role: "assistant").order(:created_at).last(2)
    expect(assistants.last.metadata.dig("webfetch", "replayed")).to be true
    expect(assistants.last.content).to eq(assistants.first.content)
    expect(payloads.count { |payload| payload[:type] == "completed" }).to eq(2)
    expect(a_request(:get, url)).to have_been_made.once
  end

  it "persists a sanitized command failure and emits failed rather than completed" do
    source_message.update!(content: "%webfetch http://127.0.0.1/private")
    expect(Quota).not_to receive(:reserve)
    expect(AgentRunner).not_to receive(:new)

    perform_command

    assistant = conversation.messages.where(role: "assistant").order(:created_at).last
    expect(assistant.metadata["error_code"]).to eq("url_forbidden")
    expect(assistant.content).to eq(WebfetchService::ERROR_MESSAGES[:url_forbidden])
    expect(webfetch_payloads.map { |payload| payload[:type] }).to eq(%w[assistant_started failed])
    expect(terminal_event).to include(type: "failed", code: "url_forbidden", message_id: assistant.id)
    expect(a_request(:get, /./)).not_to have_been_made
  end

  it "does not let an exhausted provider quota block the non-LLM command" do
    organization.update!(plan: "pro")
    create(:usage_event, organization: organization, tokens: 20_000)
    stub_request(:get, url).to_return(status: 200, body: "no model needed", headers: { "Content-Type" => "text/plain" })

    perform_command

    expect(conversation.messages.where(role: "assistant").last.content).to include("no model needed")
    expect(UsageEvent.where(organization_id: organization.id).count).to eq(1)
    expect(a_request(:get, url)).to have_been_made.once
  end

  it "honors organization disable before network and still finalizes with a failed frame" do
    organization.update!(settings: { "capabilities" => { "webfetch" => false } })
    expect(Quota).not_to receive(:reserve)
    expect(AgentRunner).not_to receive(:new)

    perform_command

    expect(terminal_event).to include(type: "failed", code: "capability_unavailable")
    expect(Resolv).not_to have_received(:getaddresses)
    expect(a_request(:get, url)).not_to have_been_made
  end

  it "rejects a source message outside the acting user's conversation before quota or network" do
    other_user = create(:user)
    other_conversation = create(:conversation, user: other_user, agent: agent)
    foreign_message = create(:message, conversation: other_conversation, content: "%webfetch #{url}")
    expect(Quota).not_to receive(:reserve)
    expect(AgentRunner).not_to receive(:new)

    perform_command(message_id: foreign_message.id)

    expect(terminal_event[:type]).to eq("failed")
    expect(Resolv).not_to have_received(:getaddresses)
    expect(a_request(:get, url)).not_to have_been_made
  end

  it "honors Stop while an explicit webfetch request is in flight" do
    stub_request(:get, url).to_return do
      placeholder = conversation.messages.where(role: "assistant").order(:created_at).last
      placeholder.update!(metadata: placeholder.metadata.merge("stop_requested" => true))
      { status: 200, body: "must not be delivered", headers: { "Content-Type" => "text/plain" } }
    end

    perform_command

    assistant = conversation.messages.where(role: "assistant").order(:created_at).last
    expect(assistant.metadata["error_code"]).to eq("cancelled")
    expect(assistant.content).to eq(WebfetchService::ERROR_MESSAGES[:cancelled])
    expect(terminal_event[:type]).to eq("stopped")
    expect(a_request(:get, url)).to have_been_made.once
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers, RSpec/MessageSpies
