# frozen_string_literal: true

require "rails_helper"

# One row per signed-in device: the token itself lives only in the browser, and
# this table keeps a hash of it.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

RSpec.describe AuthSession do
  subject(:user) { create(:user) }

  describe ".start" do
    it "gives the caller the token once and stores only its digest" do
      session = described_class.start(user, user_agent: "Chrome", ip: "203.0.113.9")

      expect(session.token).to be_present
      expect(session.token_digest).to eq(described_class.digest(session.token))
      expect(session.token_digest).not_to eq(session.token)
      expect(session.ip).to eq("203.0.113.9")
    end

    it "mints a different token for every sign-in" do
      expect(described_class.start(user).token).not_to eq(described_class.start(user).token)
    end
  end

  describe ".find_by_token" do
    it "resolves the token the browser sends back" do
      session = described_class.start(user)

      expect(described_class.find_by_token(session.token)).to eq(session)
    end

    it "finds nothing for a blank or an unknown token" do
      described_class.start(user)

      expect(described_class.find_by_token("")).to be_nil
      expect(described_class.find_by_token(nil)).to be_nil
      expect(described_class.find_by_token("not-a-token")).to be_nil
    end
  end

  describe ".describe" do
    it "names the browser and the system from the user agent" do
      ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
           "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

      expect(described_class.describe(ua)).to eq("Chrome · macOS")
    end

    it "recognises the Flutter client by its Dart socket user agent" do
      expect(described_class.describe("Dart/3.9 (dart:io)")).to eq("Shams mobile app")
    end

    it "falls back rather than storing a raw user agent" do
      expect(described_class.describe(nil)).to eq("Unknown device")
      expect(described_class.describe("curl/8.7.1")).to eq("Unknown device")
    end
  end

  describe "#usable_for?" do
    it "is true while the row stands and the user has pulled no lever" do
      session = described_class.start(user)

      expect(session.usable_for?(user)).to be(true)
    end

    it "is false once revoked" do
      session = described_class.start(user)
      session.update!(revoked_at: Time.current)

      expect(session.usable_for?(user)).to be(false)
    end

    it "is false for any session issued before 'sign out everywhere'" do
      before_the_lever = described_class.start(user)

      user.update!(sessions_invalid_before: Time.current)
      after = travel_to(1.second.from_now) { described_class.start(user) }

      expect(before_the_lever.reload.usable_for?(user)).to be(false)
      expect(after.usable_for?(user)).to be(true)
    end
  end

  describe ".visible" do
    it "leaves out revoked rows and rows nobody has used for a month" do
      fresh = described_class.start(user)
      gone = described_class.start(user)
      revoked = described_class.start(user)
      stale = described_class.start(user)

      gone.update_columns(last_seen_at: 2.months.ago)
      revoked.update!(revoked_at: Time.current)
      stale.update_columns(last_seen_at: (described_class::STALE_AFTER + 1.day).ago)

      expect(user.auth_sessions.visible).to contain_exactly(fresh)
    end

    it "shows the most recently used first" do
      old = described_class.start(user)
      recent = described_class.start(user)
      old.update_columns(last_seen_at: 2.hours.ago)
      recent.update_columns(last_seen_at: 1.minute.ago)

      expect(user.auth_sessions.visible.to_a).to eq([ recent, old ])
    end

    it "lists at most 25 devices" do
      27.times { described_class.start(user) }

      expect(user.auth_sessions.visible.count).to eq(25)
    end
  end

  describe "#touch_seen!" do
    it "writes at most once per interval" do
      session = described_class.start(user)
      first = session.last_seen_at

      session.touch_seen!
      expect(session.reload.last_seen_at).to eq(first)

      travel_to(described_class::SEEN_WRITE_INTERVAL.from_now + 1.second) do
        session.touch_seen!
        expect(session.reload.last_seen_at).to be > first
      end
    end
  end

  describe ".revoke_all_but" do
    it "ends every other session and keeps this one" do
      current = described_class.start(user)
      others = Array.new(2) { described_class.start(user) }
      stranger = create(:user)
      kept = described_class.start(stranger)

      described_class.revoke_all_but(user, current)

      expect(others.map(&:reload).map(&:revoked?)).to all(be(true))
      expect(current.reload.revoked?).to be(false)
      expect(kept.reload.revoked?).to be(false)
    end

    it "revokes everything when there is no session to keep" do
      sessions = Array.new(2) { described_class.start(user) }

      described_class.revoke_all_but(user, nil)

      expect(sessions.map(&:reload).map(&:revoked?)).to all(be(true))
    end
  end

  describe ".prune!" do
    it "deletes stale revoked rows and leaves everything else" do
      dead = described_class.start(user)
      dead.update!(revoked_at: 2.months.ago)
      dead.update_columns(last_seen_at: 2.months.ago)
      alive_but_old = described_class.start(user)
      alive_but_old.update_columns(last_seen_at: 2.months.ago)

      expect { described_class.prune! }.to change(described_class, :count).by(-1)
      expect(described_class.exists?(alive_but_old.id)).to be(true)
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
