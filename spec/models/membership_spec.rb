# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

RSpec.describe Membership, type: :model do
  let(:owner) { create(:user) }
  let(:organization) { create(:organization, owner: owner) }
  let!(:owner_membership) { create(:membership, user: owner, organization: organization, role: "owner") }
  let(:user) { create(:user) }
  let(:membership) { create(:membership, user: user, organization: organization) }

  it "rejects an owner membership for someone who is not the organization owner" do
    membership = described_class.new(user: user, organization: organization, role: :owner)

    expect(membership).not_to be_valid
    expect(membership.errors[:role]).to include("is reserved for the organization owner")
  end

  it "blocks promoting an existing membership to owner" do
    expect(membership.update(role: :owner)).to be(false)
    expect(membership.reload.role).to eq("member")
  end

  it "blocks demoting an owner membership" do
    expect(owner_membership.update(role: :admin)).to be(false)
    expect(owner_membership.reload.role).to eq("owner")
  end

  it "blocks direct destruction of an owner membership" do
    expect(owner_membership.destroy).to be(false)
    expect(owner_membership.errors[:base]).to include("Organization owners cannot be removed")
    expect(owner_membership.reload).to be_persisted
  end

  it "protects the organization owner even when a legacy membership role is not owner" do
    owner_membership.update_columns(role: "admin")

    expect(owner_membership.destroy).to be(false)
    expect(owner_membership.reload).to be_persisted
    expect(organization.reload.owner).to eq(owner)
  end

  it "blocks Organization#remove_user from removing the owner" do
    expect(organization.remove_user(owner)).to be(false)
    expect(owner_membership.reload).to be_persisted
  end

  it "still destroys an ordinary membership directly and through remove_user" do
    expect(membership.destroy).to be_destroyed

    another = create(:membership, user: create(:user), organization: organization)
    expect(organization.remove_user(another.user)).to be_destroyed
  end

  it "still allows organization destruction to cascade through owner memberships" do
    expect { organization.destroy }.to change(described_class, :count).by(-1)
    expect(organization).to be_destroyed
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
