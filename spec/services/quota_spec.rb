# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

RSpec.describe Quota do
  let(:organization) { create(:organization) }
  let(:agent) { create(:agent, organization: organization) }

  describe "cap_for" do
    it "meters only the plan that a paid membership unlocks" do
      expect(described_class.cap_for(organization)).to be_nil

      organization.update!(plan: "pro")
      expect(described_class.cap_for(organization)).to eq(20_000)
    end

    it "meters nothing without an organization" do
      expect(described_class.cap_for(nil)).to be_nil
    end
  end

  describe "estimate" do
    it "reserves the prompt plus the agent's full output cap" do
      agent.update!(config: { "max_tokens" => 1_000 })

      expect(described_class.estimate(agent, "a" * 400)).to eq(400 / 4 + 2_048 + 1_000)
    end

    it "falls back to the client default when the agent sets no cap" do
      agent.update!(config: {})

      expect(described_class.estimate(agent, "hi")).to eq(1 + 2_048 + 4_096)
    end
  end

  describe "reserve/settle" do
    it "writes a reservation the ledger counts as used" do
      before = described_class.used_today(organization)
      reservation = described_class.reserve(organization, estimate: 500)

      expect(reservation.metadata["state"]).to eq("reserved")
      expect(described_class.used_today(organization)).to eq(before + 500)

      described_class.settle(reservation, actual: 120)

      expect(reservation.reload.tokens).to eq(120)
      expect(reservation.metadata["state"]).to eq("settled")
      expect(described_class.used_today(organization)).to eq(before + 120)
    end

    it "refuses the turn that would cross the ceiling" do
      organization.update!(plan: "pro")
      create(:usage_event, organization: organization, tokens: 19_900)

      expect { described_class.reserve(organization, estimate: 200) }
        .to raise_error(Quota::Exceeded, /all 20000 tokens for today/)
    end

    it "never raises for an unmetered plan" do
      create(:usage_event, organization: organization, tokens: 5_000_000)

      expect(described_class.reserve(organization, estimate: 200)).to be_persisted
    end

    it "counts nothing from yesterday" do
      organization.update!(plan: "pro")
      old = create(:usage_event, organization: organization, tokens: 19_900)
      old.update_column(:created_at, 2.days.ago)

      expect(described_class.used_today(organization)).to eq(0)
      expect(described_class.reserve(organization, estimate: 500)).to be_persisted
    end

    it "keeps the worst case when the turn reports no count at all" do
      reservation = described_class.reserve(organization, estimate: 700)
      described_class.settle(reservation, actual: nil)

      expect(reservation.reload.tokens).to eq(700)
    end

    it "does not meter an organization that does not exist" do
      expect(described_class.reserve(nil, estimate: 700)).to be_nil
    end
  end
end
