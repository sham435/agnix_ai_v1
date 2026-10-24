# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# Library Document-Upload Flow — client wiring (spec: search, preview,
# pending-extraction, auto-library, draft-token submission gap).
#
# The backend halves are covered by spec/requests/api/v1/assets_spec.rb and the
# draft-consume case in attachment_drafts_spec.rb. This spec proves the browser
# actually (a) carries the per-conversation draft token on submit — the gap that
# let already-sent chips resurrect after a reload — and (b) surfaces the Library
# search box, preview affordance, and inline preview text.
RSpec.describe "Library document upload flow", :js, type: :system do
  let!(:user) { User.create!(email: "library@example.com", password: "password123", name: "Lib") }
  let!(:org) do
    o = Organization.create!(name: "Library Org", slug: "library-org", owner: user)
    Membership.create!(user: user, organization: o, role: "owner")
    o
  end
  let!(:agent) do
    Agent.create!(name: "Lib Agent", slug: "lib-agent", system_prompt: "hi",
                  organization: org, provider: "anthropic", model: "claude-sonnet-4-6", tools: [])
  end
  let!(:conversation) { Conversation.create!(user: user, agent: agent, title: "Library") }

  def chat_input_controller
    page.evaluate_script(<<~JS)
      (() => {
        const form = document.querySelector('form[data-controller~="chat-input"]');
        return !!form && !!window.Stimulus.getControllerForElementAndIdentifier(form, 'chat-input');
      })()
    JS
  end

  it "injects the per-conversation draft token into the form before submit" do
    login_as user
    visit conversation_path(conversation)
    expect(chat_input_controller).to be(true)

    token = page.evaluate_script(<<~JS)
      (() => {
        const form = document.querySelector('form[data-controller~="chat-input"]');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(form, 'chat-input');
        const val = ctrl.ensureDraftTokenField();
        const input = form.querySelector('input[type=hidden][name="message[attachment_draft_token]"]');
        return (input && input.value === val) ? val : null;
      })()
    JS
    expect(token).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "lists library files with a search box and opens an inline preview" do
    asset = Asset.create!(user: user, filename: "guide.pdf", content_type: "application/pdf",
                          byte_size: 1234, checksum: SecureRandom.hex(32), status: "ready",
                          metadata: { "category" => "document", "ext" => "pdf" })
    AssetExtraction.create!(asset: asset, status: "completed", content: "the extracted guide body", meta: {})
    LibraryItem.create!(user: user, asset: asset)

    login_as user
    visit conversation_path(conversation)

    find('button[title="Add from Library"]').click
    expect(page).to have_css('[data-chat-input-target~="librarySearch"]', wait: 5)
    expect(page).to have_text("guide.pdf", wait: 5)
    expect(page).to have_css("[data-preview-id]", wait: 5)

    first("[data-preview-id]").click
    expect(page).to have_text("the extracted guide body", wait: 5)
  end

  it "filters the library by search query" do
    %w[alpha-report.txt beta-notes.txt].each do |name|
      a = Asset.create!(user: user, filename: name, content_type: "text/plain",
                        byte_size: 10, checksum: SecureRandom.hex(32), status: "ready",
                        metadata: { "category" => "text", "ext" => "txt" })
      AssetExtraction.create!(asset: a, status: "completed", content: "x", meta: {})
      LibraryItem.create!(user: user, asset: a)
    end

    login_as user
    visit conversation_path(conversation)
    find('button[title="Add from Library"]').click
    expect(page).to have_text("alpha-report.txt", wait: 5)

    find('[data-chat-input-target~="librarySearch"]').set("beta")
    expect(page).to have_text("beta-notes.txt", wait: 5)
    expect(page).to have_no_text("alpha-report.txt", wait: 5)
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
