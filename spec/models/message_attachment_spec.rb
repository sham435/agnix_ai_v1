# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe MessageAttachment do
  it { expect(build(:message_attachment)).to be_valid }

  it "is unique per message+asset (no duplicate chip rows)" do
    ma = create(:message_attachment)
    expect { create(:message_attachment, message: ma.message, asset: ma.asset) }
      .to raise_error { |e| expect([ ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid ]).to include(e.class) }
  end

  it "validates and filters assets through Message#attach_assets!" do
    user = create(:user)
    other = create(:user)
    conversation = create(:conversation, user: user, agent: create(:agent))
    message = create(:message, conversation: conversation)
    own = create(:asset, user: user)
    foreign = create(:asset, user: other)

    expect(message.attach_assets!([ own.id.to_s, foreign.id.to_s ], for_user: user)).to be(true)

    expect(message.message_attachments.count).to eq(1)
    expect(message.assets.first.id).to eq(own.id)
    # The cross-user asset must never be attached.
    expect(message.asset_ids).not_to include(foreign.id)
  end
end
