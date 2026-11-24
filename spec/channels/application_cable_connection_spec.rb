# frozen_string_literal: true

# rubocop:disable RSpec/SpecFilePathFormat

require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user, email: "cable-connection-owner@example.test") }
  let(:auth_session) { AuthSession.start(user) }

  before do
    cookies.signed[:user_id] = user.id
    cookies.signed[:auth_token] = auth_session.token
  end

  it "connects with a signed user and its active device session" do
    connect

    expect([ connection.current_user, connection.current_auth_session_id ]).to eq([ user, auth_session.id ])
  end

  it "rejects a signed user cookie without a device token" do
    cookies.signed.delete(:auth_token)

    expect { connect }.to have_rejected_connection
  end

  it "rejects a device token that belongs to another user" do
    other_auth = AuthSession.start(create(:user, email: "cable-other-user@example.test"))
    cookies.signed[:auth_token] = other_auth.token

    expect { connect }.to have_rejected_connection
  end

  it "rejects a revoked device session" do
    auth_session.update!(revoked_at: Time.current)

    expect { connect }.to have_rejected_connection
  end

  it "rejects a device issued before sign-out-everywhere" do
    user.update!(sessions_invalid_before: 1.second.from_now)

    expect { connect }.to have_rejected_connection
  end
end

# rubocop:enable RSpec/SpecFilePathFormat
