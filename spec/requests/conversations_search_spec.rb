# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Phase 1c — GET /conversations/search (⌘K command palette endpoint).
#
# The endpoint must be hard-scoped to the signed-in user's ACTIVE conversations
# and expose a stable, compact JSON shape. Authorization and querying live in
# the Conversation.search model helper; these specs prove the contract.
RSpec.describe "Conversations search", type: :request do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:agent) { create(:agent) }

  def create_conversation(owner, title, status: "active")
    create(:conversation, user: owner, agent: agent, title: title, status: status)
  end

  describe "authentication" do
    it "rejects an anonymous JSON request with 401" do
      get search_conversations_path(format: :json)
      expect(response.status).to eq(401)
    end
  end

  describe "authorization + scoping" do
    before { api_login(user) }

    it "returns only the requester's conversations" do
      mine = create_conversation(user, "My quarterly report draft")
      theirs = create_conversation(other, "Their secret plan")

      get search_conversations_path(format: :json), params: { q: "plan" }
      body = JSON.parse(response.body)
      ids = body["results"].map { |r| r["id"] }

      expect(ids).not_to include(theirs.id)
      # A blank query returns the recent list — still owner-scoped.
      get search_conversations_path(format: :json)
      ids_all = JSON.parse(response.body)["results"].map { |r| r["id"] }
      expect(ids_all).to include(mine.id)
      expect(ids_all).not_to include(theirs.id)
    end

    it "never lists archived conversations" do
      archived = create_conversation(user, "Old archived thing", status: "archived")
      get search_conversations_path(format: :json), params: { q: "archived" }
      ids = JSON.parse(response.body)["results"].map { |r| r["id"] }
      expect(ids).not_to include(archived.id)
    end
  end

  describe "filtering + shape" do
    it "matches on title case-insensitively and returns the documented keys" do
      api_login(user)
      hit = create_conversation(user, "Kubernetes migration notes")
      create_conversation(user, "Unrelated grocery list")

      get search_conversations_path(format: :json), params: { q: "kubernetes" }
      body = JSON.parse(response.body)
      expect(response.status).to eq(200)
      expect(body["query"]).to eq("kubernetes")
      expect(body["results"].size).to eq(1)

      result = body["results"].first
      expect(result["id"]).to eq(hit.id)
      expect(result["title"]).to eq("Kubernetes migration notes")
      expect(result["agent"]).to eq(agent.name)
      expect(result["path"]).to eq(conversation_path(hit))
      expect(result).to have_key("updated_at")
    end

    it "returns an empty result set for a non-matching term" do
      api_login(user)
      create_conversation(user, "Something real")
      get search_conversations_path(format: :json), params: { q: "zzzznomatch" }
      expect(JSON.parse(response.body)["results"]).to eq([])
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
