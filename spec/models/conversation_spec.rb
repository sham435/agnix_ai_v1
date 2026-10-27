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
end
