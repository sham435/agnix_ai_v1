require "rails_helper"

RSpec.describe "Owner tunnel status", type: :request do
  it "rejects unauthenticated status reads" do
    get "/api/v1/owner/tunnel"
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects unauthenticated refreshes" do
    post "/api/v1/owner/tunnel/refresh"
    expect(response).to have_http_status(:unauthorized)
  end

  context "with a configured owner" do
    let(:secret) { ROTP::Base32.random }
    let(:owner) { create(:user, otp_enabled: true, otp_secret: secret) }
    let(:organization) { create(:organization, owner: owner) }

    around do |example|
      previous = ENV["SHAMS_PLATFORM_ORGANIZATION_ID"]
      ENV["SHAMS_PLATFORM_ORGANIZATION_ID"] = organization.id.to_s
      example.run
    ensure
      ENV["SHAMS_PLATFORM_ORGANIZATION_ID"] = previous
    end

    before do
      create(:membership, :owner, user: owner, organization: organization)
      post "/api/v1/sessions", params: { email: owner.email, password: "password123" }
      post "/api/v1/sessions", params: { email: owner.email, password: "password123", code: ROTP::TOTP.new(secret).now }
      allow(Tunnel::Status).to receive(:new).and_return(double(call: { status: "degraded", verified_url: nil }))
    end

    it "accepts a real password and TOTP challenge before status access" do
      get "/api/v1/owner/tunnel"
      expect(response).to have_http_status(:ok)
    end

    it "refreshes with the existing authenticated session and CSRF protection" do
      get "/api/v1/csrf"
      token = response.parsed_body["token"]
      post "/api/v1/owner/tunnel/refresh", headers: { "X-CSRF-Token" => token }
      expect(response).to have_http_status(:ok)
    end

    it "rejects a revoked device" do
      owner.auth_sessions.update_all(revoked_at: Time.current)
      get "/api/v1/owner/tunnel"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects expired MFA proof" do
      travel 13.hours
      get "/api/v1/owner/tunnel"
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects cross-organization access" do
      get "/api/v1/owner/tunnel", params: { organization_id: SecureRandom.uuid }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "rejects ordinary signed-in users before reading supervisor state" do
    user = create(:user)
    post "/api/v1/sessions", params: { email: user.email, password: "password123" }
    get "/api/v1/owner/tunnel"
    expect(response).to have_http_status(:forbidden)
  end
end
