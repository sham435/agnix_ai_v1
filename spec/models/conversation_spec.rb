# frozen_string_literal: true

require "rails_helper"

RSpec.describe Conversation, type: :model do
  let(:conversation) { create(:conversation) }

  describe "#context_messages" do
    it "drops a legacy dot-only assistant row from LLM context" do
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: ".")

      context = conversation.context_messages
      expect(context.map { |m| m[:role] }).to eq(%w[user])
    end

    it "drops '..' and '...' rows too" do
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: "..")
      conversation.messages.create!(role: "assistant", content: "...")

      context = conversation.context_messages
      expect(context.map { |m| m[:content] }).to eq([ "hi" ])
    end

    it "drops a blank assistant streaming placeholder from LLM context" do
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: "", metadata: { "streaming" => true })

      context = conversation.context_messages
      expect(context.map { |m| m[:role] }).to eq(%w[user])
    end

    it "drops any blank assistant row (finalized empty response)" do
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: "", metadata: { "empty_response" => true })

      context = conversation.context_messages
      expect(context.map { |m| m[:role] }).to eq(%w[user])
    end

    it "keeps real assistant text" do
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: "hello there")

      context = conversation.context_messages
      expect(context.map { |m| m[:role] }).to eq(%w[user assistant])
      expect(context.last[:content]).to eq("hello there")
    end

    it "keeps user messages even when they consist of a single dot (real content)" do
      conversation.messages.create!(role: "user", content: ".")

      context = conversation.context_messages
      expect(context.map { |m| m[:content] }).to eq([ "." ])
    end

    it "keeps assistant messages that begin with a period but have real body" do
      conversation.messages.create!(role: "assistant", content: ".NET is a good framework")

      context = conversation.context_messages
      expect(context.length).to eq(1)
      expect(context.first[:content]).to eq(".NET is a good framework")
    end
  end

  describe "#placeholder_assistant?" do
    it "returns true for streaming assistant" do
      m = conversation.messages.new(role: "assistant", content: "", metadata: { "streaming" => true })
      expect(conversation.placeholder_assistant?(m)).to be true
    end

    it "returns true for legacy dots" do
      m = conversation.messages.new(role: "assistant", content: ".")
      expect(conversation.placeholder_assistant?(m)).to be true
    end

    it "returns false for a real assistant reply" do
      m = conversation.messages.new(role: "assistant", content: "hi")
      expect(conversation.placeholder_assistant?(m)).to be false
    end

    it "returns false for a user message with dot content" do
      m = conversation.messages.new(role: "user", content: ".")
      expect(conversation.placeholder_assistant?(m)).to be false
    end
  end

  # Deadlock regression: PG::TRDeadlockDetected 'while updating tuple ... in
  # relation "agents"'. Two concurrent AgentStreamJobs on ONE conversation took
  # the same two rows in opposite orders — a Message write went
  # conversations -> agents (counter_cache + touch chain, the agents hop coming
  # from the old `belongs_to :agent, touch: true`), while Run.create! went
  # agents -> conversations (counter_cache on agents, touch on conversations).
  # Message writes must never reach for the agents row; that is what closes the
  # cycle, so these examples pin the SQL each path emits.
  describe "row lock order" do
    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql]
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def updates_to(sql, table)
      sql.grep(/^UPDATE "#{table}" /)
    end

    it "writes a message without locking the agents (or organizations) row" do
      conversation # resolve the lazy factory row outside the captured window
      sql = capture_sql { conversation.messages.create!(role: "user", content: "hi") }

      expect(updates_to(sql, "conversations")).not_to be_empty
      expect(updates_to(sql, "agents")).to be_empty
      expect(updates_to(sql, "organizations")).to be_empty
    end

    it "leaves agents.updated_at alone while conversation activity continues" do
      agent = conversation.agent
      before = agent.updated_at

      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: "hello")

      expect(agent.reload.updated_at).to eq(before)
    end

    it "still records the run-side lock order (agents before conversations)" do
      # Documented on purpose: this path is the other half of the cycle. It may
      # keep that order only because the message path no longer takes agents.
      run = build(:run, agent: conversation.agent, conversation: conversation)

      sql = capture_sql { run.save! }

      expect(updates_to(sql, "agents")).not_to be_empty
      expect(updates_to(sql, "conversations")).not_to be_empty
    end
  end
end
