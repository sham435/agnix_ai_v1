# spec/system/composer_spec.rb
# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Chat composer", :js, type: :system do
  let!(:user) do
    User.create!(email: "composer@example.com", password: "password123", name: "Composer")
  end

  let!(:agent) do
    org = Organization.create!(name: "Composer Org", slug: "composer-org", owner: user)
    Membership.create!(user: user, organization: org, role: "owner")
    Agent.create!(
      name: "Composer Agent",
      slug: "composer-agent",
      system_prompt: "You are helpful.",
      organization: org,
      tools: []
    )
  end

  before do
    stub_request(:post, %r{api\.anthropic\.com/v1/messages})
      .to_return(
        status: 200,
        body: {
          id: "msg_composer",
          type: "message",
          role: "assistant",
          content: [ { type: "text", text: "Hello there!" } ],
          model: "claude-sonnet-4-6",
          stop_reason: "end_turn",
          usage: { input_tokens: 10, output_tokens: 5 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: { data: [ { embedding: [ 0.1 ] * 1536, index: 0 } ], usage: { prompt_tokens: 4, total_tokens: 4 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  it "sends the draft with Enter instead of inserting a newline" do
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)

    stub_composer_desktop!
    fill_in "message-input", with: "Hello from Chrome"
    find("#message-input").send_keys(:enter)

    # A successful submit clears the composer (turbo:submit-end -> clear).
    # If Enter had only inserted a newline, the draft would still be there.
    expect(page).to have_field("message-input", with: "", wait: 5)
  end

  it "keeps the draft on a new line when Shift+Enter is pressed" do
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)

    stub_composer_desktop!
    fill_in "message-input", with: "line one"
    find("#message-input").send_keys(%i[shift enter])

    expect(page).to have_field("message-input", with: "line one\n", wait: 5)
  end

  it "queues with Enter and steers with Cmd+Enter while the first run stays active" do
    allow(AgentStreamJob).to receive(:perform_later)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)
    stub_composer_desktop!

    fill_in "message-input", with: "Start the task"
    find("#message-input").send_keys(:enter)
    expect(page).to have_field("message-input", with: "", wait: 5)
    expect(page).to have_css("[data-chat-input-target='taskStatus']",
      text: "Background tasks running: 1 · You can keep messaging.", wait: 5)

    fill_in "message-input", with: "Queued follow-up"
    find("#message-input").send_keys(:enter)
    expect(page).to have_field("message-input", with: "", wait: 5)
    expect(page).to have_css("[data-chat-input-target='taskStatus']",
      text: "Background tasks running: 1 · You can keep messaging. · 1 queued", wait: 5)
    expect(page).to have_css("[data-optimistic-user]", text: "Queued follow-up")
    expect(page).to have_css("[data-chat-input-target='taskCount']", text: "2", wait: 5)
    expect(page).to have_css("[data-chat-input-target='taskPanel']:not([hidden])", wait: 5)

    fill_in "message-input", with: "Steer the approach"
    find("#message-input").send_keys([ :meta, :enter ])
    expect(page).to have_field("message-input", with: "", wait: 5)
    expect(page).to have_content("Steering queued for the next safe step.", wait: 5)
    expect(conversation.messages.where(role: "user").count).to eq(1)
    expect(conversation.reload.metadata["m18_followups"].size).to eq(1)
    expect(conversation.metadata["m18_steering"].size).to eq(1)
    expect(page).to have_css("[data-chat-input-target='taskCount']", text: "3", wait: 5)
    find("[data-chat-input-target='taskPanel'] summary").click
    within "[data-chat-input-target='taskList']" do
      expect(page).to have_css("li[data-task-state='queued']", count: 2)
      expect(page).to have_content("Queued follow-up")
      expect(page).to have_content("Steering instruction")
    end
  end

  it "restores queued follow-ups and steering after navigation and refresh" do
    allow(AgentStreamJob).to receive(:perform_later)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Persistent queue")
    visit conversation_path(conversation)
    stub_composer_desktop!

    fill_in "message-input", with: "Start the task"
    find("#message-input").send_keys(:enter)
    expect(page).to have_field("message-input", with: "", wait: 5)
    fill_in "message-input", with: "Persistent follow-up"
    find("#message-input").send_keys(:enter)
    expect(page).to have_css("[data-chat-input-target='taskCount']", text: "2", wait: 5)
    fill_in "message-input", with: "Persistent steering"
    find("#message-input").send_keys([ :meta, :enter ])
    expect(page).to have_css("[data-chat-input-target='taskCount']", text: "3", wait: 5)

    visit images_path(conversation_id: conversation.id)
    find('a[aria-label="Back to chat"]').click
    expect(page).to have_css(
      "[data-chat-input-target='taskStatus']",
      text: "Background tasks running: 1 · You can keep messaging. · 2 queued",
      wait: 5
    )
    page.refresh
    expect(page).to have_css(
      "[data-chat-input-target='taskStatus']",
      text: "Background tasks running: 1 · You can keep messaging. · 2 queued",
      wait: 5
    )

    find("[data-chat-input-target='taskPanel'] summary").click
    within "[data-chat-input-target='taskList']" do
      expect(page).to have_content("Persistent follow-up")
      expect(page).to have_content("Persistent steering")
    end
    expect(conversation.reload.metadata["m18_followups"].size).to eq(1)
    expect(conversation.metadata["m18_steering"].size).to eq(1)
    expect(conversation.messages.where(role: "user").count).to eq(1)
    expect(AgentStreamJob).to have_received(:perform_later).once
  end

  it "reconciles a persisted active run and steers it with Ctrl+Enter" do
    allow(AgentStreamJob).to receive(:perform_later)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Long running")
    create(:run, :running, agent: agent, conversation: conversation,
      metadata: { "request_id" => "long-running-request" })
    visit conversation_path(conversation)
    stub_composer_desktop!

    expect(page).to have_css("[data-chat-input-target='taskStatus']",
      text: "Background tasks running: 1 · You can keep messaging.", wait: 5)
    reconciliation = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const form = document.querySelector("[data-controller~='chat-input']")
      const controller = window.Stimulus.getControllerForElementAndIdentifier(form, "chat-input")
      controller.reconcileTaskStatus().then(() => done()).catch(() => done("failed"))
    JS
    expect(reconciliation).not_to eq("failed")

    fill_in "message-input", with: "Steer with control"
    find("#message-input").send_keys([ :control, :enter ])

    expect(page).to have_field("message-input", with: "", wait: 5)
    expect(conversation.reload.metadata["m18_steering"].last["content"]).to eq("Steer with control")
    expect(conversation.messages.where(role: "user").count).to eq(0)
  end

  it "shows a manual plan waiting for approval and queues instead of starting a concurrent run" do
    allow(AgentStreamJob).to receive(:perform_later)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Manual plan")
    create(:agent_run, conversation: conversation, mode: "manual_plan", status: "planning")
    visit conversation_path(conversation)
    stub_composer_desktop!

    find("[data-chat-input-target='taskPanel'] summary").click
    within "[data-chat-input-target='taskList']" do
      expect(page).to have_css("li[data-task-state='waiting_for_user']")
      expect(page).to have_content("Manual plan task")
    end

    fill_in "message-input", with: "Continue after approval"
    find("#message-input").send_keys(:enter)

    expect(page).to have_field("message-input", with: "", wait: 5)
    expect(conversation.reload.metadata["m18_followups"].last["content"]).to eq("Continue after approval")
    expect(conversation.messages.where(role: "user").count).to eq(0)
  end

  it "preserves the exact draft and focus when the queue is full" do
    allow(AgentStreamJob).to receive(:perform_later)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)
    stub_composer_desktop!
    fill_in "message-input", with: "Start the task"
    find("#message-input").send_keys(:enter)
    expect(page).to have_field("message-input", with: "", wait: 5)

    Conversations::TurnAdmission::MAX_PENDING.times do |index|
      Conversations::TurnAdmission.call(conversation: conversation, user: user, params: { content: "Pending #{index}" })
    end
    draft = "Do not lose this draft\nwith its newline"
    fill_in "message-input", with: draft
    find("#message-input").send_keys(:enter)

    expect(page).to have_field("message-input", with: draft, wait: 5)
    expect(page).to have_content("Too many waiting messages", wait: 5)
    expect(page).to have_content("Your draft is preserved", wait: 5)
    expect(page).to have_css("#message-input:focus")
  end

  it "preserves newer text typed while a successful send is in flight" do
    allow(AgentStreamJob).to receive(:perform_later)
    allow(Conversations::TurnAdmission).to receive(:call).and_wrap_original do |original, **kwargs|
      sleep 0.5 if kwargs[:params][:content].to_s == "Submitted text"
      original.call(**kwargs)
    end
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Newer draft")
    visit conversation_path(conversation)
    stub_composer_desktop!

    fill_in "message-input", with: "Submitted text"
    find("#message-input").send_keys(:enter)
    fill_in "message-input", with: "Newer text stays"

    expect(page).to have_field("message-input", with: "Newer text stays", wait: 5)
    expect(page).to have_css(
      "[data-chat-input-target='taskStatus']",
      text: "Background tasks running: 1",
      wait: 5
    )
    expect(conversation.messages.where(role: "user").last.content).to eq("Submitted text")
  end

  it "preserves an attachment added while a successful send is in flight" do
    allow(AgentStreamJob).to receive(:perform_later)
    allow(Conversations::TurnAdmission).to receive(:call).and_wrap_original do |original, **kwargs|
      sleep 0.5 if kwargs[:params][:content].to_s == "Send without the new file"
      original.call(**kwargs)
    end
    asset = Asset.create!(user: user, filename: "later.txt", content_type: "text/plain", byte_size: 5,
      checksum: SecureRandom.hex(16), status: "ready", metadata: { "category" => "document" })
    LibraryItem.create!(user: user, asset: asset)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Newer attachment")
    visit conversation_path(conversation)
    stub_composer_desktop!

    fill_in "message-input", with: "Send without the new file"
    find("#message-input").send_keys(:enter)
    expect(page).to have_css("[data-optimistic-user]", text: "Send without the new file", wait: 5)
    find("button[title='Add from Library']").click
    within "[data-chat-input-target='libraryItems']" do
      find("button[data-asset-id='#{asset.id}']").click
    end

    expect(page).to have_field("message-input", with: "", wait: 5)
    within "[data-chat-input-target='chips']" do
      expect(page).to have_content("later.txt")
      expect(page).to have_css("input[name='message[attachment_asset_ids][]'][value='#{asset.id}']", visible: :all)
    end
    expect(conversation.messages.where(role: "user").sole.assets).to be_empty
  end

  it "preserves newer text typed while a queue-limit rejection is in flight" do
    allow(AgentStreamJob).to receive(:perform_later)
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Rejected newer draft")
    visit conversation_path(conversation)
    stub_composer_desktop!
    fill_in "message-input", with: "Start the task"
    find("#message-input").send_keys(:enter)
    expect(page).to have_field("message-input", with: "", wait: 5)
    Conversations::TurnAdmission::MAX_PENDING.times do |index|
      Conversations::TurnAdmission.call(conversation: conversation, user: user, params: { content: "Pending #{index}" })
    end
    allow(Conversations::TurnAdmission).to receive(:call).and_wrap_original do |original, **kwargs|
      sleep 0.5 if kwargs[:params][:content].to_s == "Rejected text"
      original.call(**kwargs)
    end

    fill_in "message-input", with: "Rejected text"
    find("#message-input").send_keys(:enter)
    fill_in "message-input", with: "Newer rejected draft stays"

    expect(page).to have_field("message-input", with: "Newer rejected draft stays", wait: 5)
    expect(page).to have_content("Too many waiting messages", wait: 5)
    expect(page).to have_css("#message-input:focus")
  end

  it "opens all four workspace quick actions with hover, keyboard, and touch-style activation" do
    allow(AgentStreamJob).to receive(:perform_later)
    allow(Workspaces::Provider).to receive(:available?).and_return({ manager: false, docker: false })
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)
    stub_composer_desktop!

    trigger = find("button[aria-label='Workspace quick actions']")
    menu = find("#workspace-quick-actions", visible: :all)
    expect(trigger[:'aria-expanded']).to eq("false")
    expect(menu[:'aria-hidden']).to eq("true")

    trigger.hover
    expect(menu).to be_visible
    find("#message-input").hover
    expect(menu).not_to be_visible

    trigger.click
    expect(trigger[:'aria-expanded']).to eq("true")
    expect(menu[:'aria-hidden']).to eq("false")
    within menu do
      expect(page).to have_link("New side task", href: new_scheduled_task_path(agent_id: agent.id))
      expect(page).to have_link("Terminal", href: workspace_panel_path(conversation_id: conversation.id, section: "terminal"))
      expect(page).to have_link("Built-in browser", href: workspace_panel_path(conversation_id: conversation.id, section: "preview"))
      expect(page).to have_link("Workspace files", href: workspace_panel_path(conversation_id: conversation.id, section: "files"))
    end
    trigger.send_keys(:escape)
    expect(menu).not_to be_visible
    expect(trigger[:'aria-expanded']).to eq("false")

    trigger.send_keys(:down)
    expect(page).to have_css("#workspace-quick-actions a:focus", text: "New side task")
    press_key(:down)
    expect(page).to have_css("#workspace-quick-actions a:focus", text: "Terminal")
    press_key(:up)
    expect(page).to have_css("#workspace-quick-actions a:focus", text: "New side task")
    press_key(:down)
    press_key(:enter)

    expect(page).to have_current_path(conversation_path(conversation))
    expect(page).to have_css("#workspace-panel[data-open='true']")
    expect(find("turbo-frame#workspace_panel_body")[:src]).to include("section=terminal")
    within "#workspace-panel" do
      expect(page).to have_content("Execution is unavailable", wait: 5)
    end
    find("button[aria-label='Close coding workspace']").click

    { "Built-in browser" => "preview", "Workspace files" => "files" }.each do |label, section|
      trigger.click
      within menu do
        click_link label
      end
      expect(page).to have_css("#workspace-panel[data-open='true']")
      expect(find("turbo-frame#workspace_panel_body")[:src]).to include("section=#{section}")
      within "#workspace-panel" do
        expect(page).to have_content("Execution is unavailable", wait: 5)
      end
      find("button[aria-label='Close coding workspace']").click
    end

    trigger.click
    within menu do
      click_link "New side task"
    end
    expect(page).to have_current_path(new_scheduled_task_path(agent_id: agent.id))
    expect(page).to have_content("New scheduled task")
    expect(ScheduledTask.count).to eq(0)
    expect(AgentStreamJob).not_to have_received(:perform_later)
  end

  def press_key(key)
    page.driver.browser.page.keyboard.type(key)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
