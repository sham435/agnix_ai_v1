# frozen_string_literal: true

# Server-backed attachment draft: one row per (user, draft_token, asset).
# The composer's JavaScript holds draft_token in localStorage and posts a row
# per uploaded/selected asset, so a Turbo-refreshed page restores its chips
# without re-uploading bytes. Message creation consumes attached drafts inside
# the same transaction, and expired rows are cleaned lazily on access.
class AttachmentDraft < ApplicationRecord
  belongs_to :user
  belongs_to :asset

  DEFAULT_TTL = 24.hours
  MAX_USER_DRAFTS = 50

  validates :draft_token, presence: true, length: { maximum: 128 }
  validates :draft_token, uniqueness: { scope: %i[user_id asset_id], case_sensitive: false }
  validates :expires_at, presence: true
  validates :label, length: { maximum: 255 }

  scope :live, -> { where(expires_at: (Time.current..)) }
  scope :expired, -> { where(expires_at: ..Time.current) }

  class << self
    # Persist (or refresh) the draft for one asset: refreshes expiry + label.
    def record!(user:, draft_token:, asset:, label: nil)
      cleanup_expired_for(user)
      make_room_for(user)

      row = where(user: user, draft_token: draft_token, asset: asset).first_or_initialize
      row.label = label.presence || asset.filename
      row.expires_at = Time.current + DEFAULT_TTL
      row.save!
      row
    end

    def live_for(user, draft_token)
      live.where(user: user, draft_token: draft_token).order(:created_at).includes(:asset)
    end

    # Consume only drafts whose asset was truly attached to the message
    # (chips the user removed were destroyed on removal; failed extraction
    # chips were never attached and legitimately survive this call).
    def consume_attached_for(user, draft_token, asset_ids)
      ids = Array(asset_ids).compact.uniq
      return if draft_token.blank? || ids.empty?

      where(user: user, draft_token: draft_token, asset_id: ids).delete_all
    end

    def cleanup_expired_for(user)
      expired.where(user: user).delete_all
    end

    private

    # Keeps the table bounded: the user's oldest live drafts are dropped when
    # above the cap. Silent self-healing — no new error surface for the client.
    def make_room_for(user)
      over = where(user: user).order(:created_at).limit([ current_count(user) - MAX_USER_DRAFTS + 1, 0 ].max)
      over.delete_all if over.size.positive?
    end

    def current_count(user)
      where(user: user).count
    end
  end
end
