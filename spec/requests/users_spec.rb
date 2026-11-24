# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# M15 Batch 1 (C1): the profile page is self-service only. Before this fix,
# `User.find(params[:id])` let any signed-in account read another user's
# email, conversations and memories, and rewrite their name/email/settings.
RSpec.describe "User profile isolation", type: :request do
  let(:user_a) { create(:user, name: "Alice") }
  let(:user_b) { create(:user, name: "Bob") }
  let(:html_headers) { { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" } }

  def seed_private_data(user)
    create(:conversation, user: user, title: "Private #{user.name} conversation")
    create(:memory, user: user, content: "Private #{user.name} memory")
  end

  context "when signed in" do
    before { api_login(user_a) }

    it "shows the signed-in user their own profile, conversations and memories" do
      seed_private_data(user_a)

      get user_path(user_a), headers: html_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(user_a.email)
      expect(response.body).to include("Private Alice conversation")
      expect(response.body).to include("Private Alice memory")
    end

    it "refuses to show another user's profile or private data" do
      seed_private_data(user_b)

      get user_path(user_b), headers: html_headers

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(user_b.email)
      expect(response.body).not_to include("Private Bob conversation")
      expect(response.body).not_to include("Private Bob memory")
    end

    it "answers another user's id exactly like a nonexistent id (no enumeration)" do
      # Serve the production-style static 404 page instead of the local-debug
      # exception page, so the comparison proves an existing account and a
      # nonexistent one are indistinguishable to the caller. The app merges
      # env_config over every request env, so override it there and restore.
      env_config = Rails.application.env_config
      original = env_config.values_at("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
      env_config["action_dispatch.show_exceptions"] = :rescuable
      env_config["action_dispatch.show_detailed_exceptions"] = false

      get user_path(user_b), headers: html_headers
      foreign_status = response.status
      foreign_body = response.body

      get "/users/999999", headers: html_headers

      expect(response.status).to eq(foreign_status)
      expect(response.body).to eq(foreign_body)
      expect(response).to have_http_status(:not_found)
    ensure
      env_config["action_dispatch.show_exceptions"], env_config["action_dispatch.show_detailed_exceptions"] = original
    end

    it "cannot modify another user's name, email or settings" do
      original = user_b.attributes.slice("name", "email", "settings")

      patch user_path(user_b),
        params: { user: { name: "Hacked", email: "hacked@evil.test", settings: { theme: "evil" } } },
        headers: html_headers

      expect(response).to have_http_status(:not_found)
      expect(user_b.reload.attributes.slice("name", "email", "settings")).to eq(original)
    end

    it "cannot change another user's email even on its own" do
      patch user_path(user_b),
        params: { user: { email: "hacked@evil.test" } },
        headers: html_headers

      expect(response).to have_http_status(:not_found)
      expect(user_b.reload.email).not_to eq("hacked@evil.test")
    end

    it "still updates the signed-in user's own name" do
      patch user_path(user_a),
        params: { user: { name: "Alice Renamed" } },
        headers: html_headers

      expect(response).to redirect_to(user_path(user_a))
      expect(user_a.reload.name).to eq("Alice Renamed")
    end

    it "no longer accepts email changes on this surface" do
      patch user_path(user_a),
        params: { user: { email: "new-identity@evil.test" } },
        headers: html_headers

      expect(response).to redirect_to(user_path(user_a))
      expect(user_a.reload.email).not_to eq("new-identity@evil.test")
    end

    it "still updates the signed-in user's own settings" do
      patch user_path(user_a),
        params: { user: { settings: { theme: "dark" } } },
        headers: html_headers

      expect(response).to redirect_to(user_path(user_a))
      expect(user_a.reload.settings["theme"]).to eq("dark")
    end

    it "renders no editable email field in the profile form" do
      get user_path(user_a), headers: html_headers

      expect(response.body).not_to include('name="user[email]"')
    end

    it "refuses another user's profile over JSON without leaking data" do
      get user_path(user_b), headers: api_headers

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(user_b.email)
    end

    it "refuses another user's update over JSON" do
      patch user_path(user_b), params: { user: { name: "Hacked" } }, headers: api_headers

      expect(response).to have_http_status(:not_found)
      expect(user_b.reload.name).not_to eq("Hacked")
    end

    it "serves no JSON profile representation even for the signed-in user" do
      get user_path(user_a), headers: api_headers

      expect(response).to have_http_status(:not_acceptable)
      expect(response.body).not_to include(user_a.email)
    end
  end

  context "when signed out" do
    it "requires authentication to view a profile" do
      get user_path(user_a)

      expect(response).to redirect_to(login_path)
    end

    it "answers JSON requests with a 401 JSON error" do
      get user_path(user_a), headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Please sign in to continue.")
    end

    it "requires authentication to update a profile" do
      patch user_path(user_a),
        params: { user: { name: "Hacked" } },
        headers: { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" }

      expect(response).to redirect_to(login_path)
      expect(user_a.reload.name).not_to eq("Hacked")
    end
  end
end
