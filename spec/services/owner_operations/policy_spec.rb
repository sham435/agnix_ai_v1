require "rails_helper"

RSpec.describe OwnerOperations::Policy do
  subject(:allowed) { described_class.allowed?(user: user, organization: organization, auth_session: auth, session: session) }

  let(:user) { double(id: "owner", second_factor_enabled?: true, owner?: true) }
  let(:organization) { double(id: "platform", owner_id: "owner") }
  let(:auth) { double(user_id: "owner", usable_for?: true, token_digest: "digest", created_at: 1.minute.ago) }
  let(:session) { { mfa_auth_digest: "digest", mfa_verified_at: Time.current.iso8601 } }


  around do |example|
    previous = ENV["SHAMS_PLATFORM_ORGANIZATION_ID"]
    ENV["SHAMS_PLATFORM_ORGANIZATION_ID"] = "platform"
    example.run
  ensure
    ENV["SHAMS_PLATFORM_ORGANIZATION_ID"] = previous
  end

  it("accepts the configured owner with session-bound MFA") { expect(allowed).to be true }

  it "fails closed without a platform binding" do
    ENV.delete("SHAMS_PLATFORM_ORGANIZATION_ID")
    expect(allowed).to be false
  end

  it "rejects another tenant" do
    allow(organization).to receive(:id).and_return("other")
    expect(allowed).to be false
  end

  it "rejects a non-owner" do
    allow(organization).to receive(:owner_id).and_return("other")
    expect(allowed).to be false
  end

  it "rejects revoked sessions" do
    allow(auth).to receive(:usable_for?).and_return(false)
    expect(allowed).to be false
  end

  it "rejects disabled MFA" do
    allow(user).to receive(:second_factor_enabled?).and_return(false)
    expect(allowed).to be false
  end

  it "rejects missing proof" do
    session.delete(:mfa_verified_at)
    expect(allowed).to be false
  end

  it "rejects expired proof" do
    session[:mfa_verified_at] = 13.hours.ago.iso8601
    expect(allowed).to be false
  end

  it "rejects proof from another session" do
    session[:mfa_auth_digest] = "another"
    expect(allowed).to be false
  end
end
