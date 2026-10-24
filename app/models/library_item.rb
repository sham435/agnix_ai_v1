# frozen_string_literal: true

# A Library entry. Points at a canonical Asset — attaching a Library item to a
# conversation or message references the same asset; no second upload or copy.
class LibraryItem < ApplicationRecord
  belongs_to :user
  belongs_to :asset

  validates :asset_id, uniqueness: { scope: :user_id }
  validates :label, length: { maximum: 255 }

  scope :for_user, ->(user) { where(user_id: user.id).order(created_at: :desc) }
end
