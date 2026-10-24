# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Dashboard new-chat thinking indicator", :js, type: :system do
  let!(:user) { create(:user) }
  let!(:organization) { create(:organization, owner: user) }
  let!(:membership) { create(:membership, user: user, organization: organization, role: "owner") }
  let!(:agent) { create(:agent, organization: organization) }

  around do |example|
    # Keep the agent job enqueued (never performed) so no real LLM call is
    # needed: the controller-provisioned streaming placeholder must already
    # render the acknowledgment + thinking dots on the redirected conversation.
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = previous
  end

  it "shows the acknowledgment and thinking dots the instant the home composer is submitted — no refresh" do
    login_as user
    visit conversations_path(agent_id: agent.id)

    expect(page).to have_css("#composer-input", wait: 10)
    stub_composer_desktop!
    find("#composer-input").set("hello")
    find("#composer-input").send_keys(:enter)

    # Turbo redirects into the freshly created conversation; the assistant
    # placeholder (with ack + dots) is rendered from the database on load.
    expect(page).to have_css("[data-thinking-ack]", text: "Your valuable input is received", count: 1, wait: 15)
    expect(page).to have_css("[data-thinking-indicator][role='status']", count: 1, wait: 5)
    expect(page).to have_content("Shams AI is thinking")

    # The user message is present, and exactly one acknowledgment exists.
    expect(page).to have_content("hello")
    expect(page.all("[data-thinking-ack]", wait: false).size).to eq(1)
  end
end
# rubocop:enable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
