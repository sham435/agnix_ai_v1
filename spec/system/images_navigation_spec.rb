# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Images contextual navigation", :js, type: :system do
  let!(:user) { create(:user) }
  let!(:organization) { create(:organization, owner: user) }
  let!(:agent) { create(:agent, organization: organization) }
  let!(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    allow(Images::GenerateJob).to receive(:perform_later)
    login_as user
    visit conversation_path(conversation)
  end

  def open_images
    find("nav a[href='#{images_path(conversation_id: conversation.id)}']").click
    expect(page).to have_current_path(images_path(conversation_id: conversation.id))
  end

  it "preserves the chat draft, image configuration, refresh and browser history" do
    fill_in "message-input", with: "Unsent chat draft"
    open_images
    fill_in "image_generation_prompt", with: "Unsent image prompt"
    select "High", from: "image_generation_quality"
    find('a[aria-label="Back to chat"]').click
    expect(page).to have_current_path(conversation_path(conversation))
    expect(page).to have_field("message-input", with: "Unsent chat draft")
    page.go_back
    expect(page).to have_field("image_generation_prompt", with: "Unsent image prompt")
    expect(page).to have_select("image_generation_quality", selected: "High")
    page.refresh
    expect(page).to have_field("image_generation_prompt", with: "Unsent image prompt")
    page.go_forward
    expect(page).to have_field("message-input", with: "Unsent chat draft")
    expect(Images::GenerateJob).not_to have_received(:perform_later)
  end

  it "preserves the conversation scroll position" do
    create_list(:message, 18, conversation: conversation, role: "user", content: "Long message " * 150)
    page.refresh
    page.execute_script("document.querySelector('#messages-container').scrollTop = 160")
    expect(page.evaluate_script("document.querySelector('#messages-container').scrollTop")).to be_within(2).of(160)
    open_images
    find('a[aria-label="Back to chat"]').click
    expect(page).to have_field("message-input")
    expect(page.evaluate_script("document.querySelector('#messages-container').scrollTop")).to be_within(2).of(160)
  end

  it "keeps a queued request running without resubmission on return" do
    open_images
    fill_in "image_generation_prompt", with: "Queued contextual image"
    click_button "Generate"
    expect(page).to have_text("Queued…")
    generation = user.image_generations.sole
    expect(generation.metadata["conversation_id"]).to eq(conversation.id)
    find('a[aria-label="Back to chat"]').click
    open_images
    page.refresh
    expect(page).to have_text("Queued…")
    expect(user.image_generations.count).to eq(1)
    expect(Images::GenerateJob).to have_received(:perform_later).once
  end

  it "retains completed images and failed details after returning to chat" do
    completed = create(:image_generation, :succeeded, user: user)
    failed = create(:image_generation, :failed, user: user, error: "Image generation rate limit. Wait before retrying.")
    open_images
    expect(page).to have_css("#image-generation-#{completed.id} img")
    expect(page).to have_text(failed.error)
    find('a[aria-label="Back to chat"]').click
    open_images
    expect(page).to have_css("#image-generation-#{completed.id} img")
    expect(page).to have_text(failed.error)
    expect(Images::GenerateJob).not_to have_received(:perform_later)
  end

  it "offers a compact accessible mobile return and a recent-chat direct fallback" do
    page.current_window.resize_to(390, 844)
    visit images_path
    back = find('a[aria-label="Back to chat"]')
    expect(back[:title]).to eq("Return to conversation")
    expect(page.evaluate_script("document.querySelector('a[aria-label=\"Back to chat\"]').getBoundingClientRect().height")).to be >= 44
    back.click
    expect(page).to have_current_path(conversation_path(conversation))
  ensure
    page.current_window.resize_to(1400, 1000)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
