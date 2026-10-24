# frozen_string_literal: true

# Join row between a chat message and the canonical Asset it references.
# No bytes are copied — the join points at the Asset descriptor.
class MessageAttachment < ApplicationRecord
  belongs_to :message
  belongs_to :asset

  # Eager-load everything the message-bubble partial renders, so per-attachment
  # chips never N+1 (asset blob + extraction status).
  scope :with_render_assets, -> { includes(asset: :extraction) }

  validates :asset_id, uniqueness: { scope: :message_id }
end
