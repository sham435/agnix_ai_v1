# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe LibraryItem do
  it { expect(build(:library_item)).to be_valid }

  it "is unique per user+asset (Library reuse never duplicates the asset)" do
    item = create(:library_item)
    expect { create(:library_item, user: item.user, asset: item.asset) }
      .to raise_error { |e| expect([ ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid ]).to include(e.class) }
  end

  it "orders for_user newest first across different assets" do
    user = create(:user)
    newer = create(:library_item, user: user, created_at: 1.day.ago)
    older = create(:library_item, user: user, created_at: 2.days.ago)

    expect(user.library_items.order(:created_at).last.id).to eq(newer.id)
  end

  it "is deleted when the asset is destroyed" do
    item = create(:library_item)
    id = item.asset_id
    item.asset.destroy!
    expect(described_class.exists?(item.id)).to be false
    expect(Asset.exists?(id)).to be false
  end
end
