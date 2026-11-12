# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/ExpectInHook

# The chat header used to paint the avatar as a plain <div>: nothing happened
# when you clicked it, and on a phone — where the sidebar holds the only real
# user menu but sits off-canvas — there was no way to reach settings or sign
# out from a conversation.

RSpec.describe "Conversation header user menu", :js, type: :system do
  let!(:user) { create(:user, name: "Header Person") }
  let!(:organization) { create(:organization, owner: user) }
  let!(:agent) { create(:agent, organization: organization) }
  let!(:conversation) { create(:conversation, user: user, agent: agent, title: "Quarterly report cleanup") }

  before do
    login_as user
    visit conversation_path(conversation)
    expect(page).to have_css("#sidebar", wait: 10)
  end

  def header_menu
    find("header [data-dropdown-target='menu']", visible: :all)
  end

  def sidebar_menu
    find("#sidebar [data-dropdown-target='menu']", visible: :all)
  end

  it "opens the account menu when the header avatar is clicked" do
    find("header button[title^='Open user menu']").click

    expect(header_menu).to be_visible
    expect(header_menu).to have_link("Account settings")
    expect(all("[data-dropdown-target='menu']", visible: true).count).to eq(1)
  end

  it "sends the g-then-a shortcut to one menu, not both" do
    %w[g a].each do |key|
      page.evaluate_script("document.dispatchEvent(new KeyboardEvent('keydown', {key: '#{key}', bubbles: true}))")
    end

    expect(header_menu).to be_visible
    expect(sidebar_menu).not_to be_visible
  end
end
