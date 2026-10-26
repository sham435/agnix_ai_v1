# frozen_string_literal: true

# == Schema Information
#
# Table name: image_generations
#
#  id              :uuid             not null, primary key
#  asset_id        :uuid
#  error           :text
#  metadata        :jsonb            default({}), not null
#  model           :string           default("gpt-image-1"), not null
#  n               :integer          default(1), not null
#  organization_id :uuid
#  prompt          :text             not null
#  provider        :string           default("openai"), not null
#  quality         :string           default("auto"), not null
#  size            :string           default("1024x1024"), not null
#  status          :string           default("queued"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :uuid             not null
#
# Phase 3 — Image Generation. One row per generation request: the canonical
# user-facing record behind the /images gallery and the in-chat tool. Bytes
# land in a normal Asset through the existing ingest pipeline; `asset_id` is
# the link once the provider image has been stored. Provider detail
# (revised_prompt, provider response ids) and chat linkage (conversation_id)
# live in metadata so the schema stays closed while the surface stays honest.
class ImageGeneration < ApplicationRecord
  belongs_to :user
  belongs_to :organization, optional: true
  belongs_to :asset, optional: true

  enum :status,
       { queued: "queued", running: "running", succeeded: "succeeded", failed: "failed" },
       default: :queued

  PROVIDERS = %w[openai].freeze
  SIZES = %w[1024x1024 1024x1536 1536x1024 auto].freeze
  QUALITIES = %w[auto low medium high].freeze
  MODELS = %w[gpt-image-1 dall-e-3].freeze

  # Queued or running: blocks a second in-chat generation for the same
  # conversation and renders a skeleton in the gallery.
  scope :in_flight, -> { where(status: %w[queued running]) }
  scope :for_conversation, ->(conversation_id) {
    where("metadata->>'conversation_id' = ?", conversation_id.to_s)
  }

  validates :prompt, presence: true
  validates :provider, inclusion: { in: PROVIDERS }
  validates :model, inclusion: { in: MODELS }
  validates :size, inclusion: { in: SIZES }
  validates :quality, inclusion: { in: QUALITIES }
  validates :n, numericality: { only_integer: true, in: 1..4 }

  # True while a queued/running generation exists for the conversation — the
  # in-chat tool refuses while this holds (one image job per conversation).
  def self.in_flight_for_conversation?(conversation_id)
    return false if conversation_id.blank?

    in_flight.for_conversation(conversation_id).exists?
  end

  # Merge provider detail / chat linkage into the jsonb metadata. Tolerates
  # the raw-string column default ("{}") a fresh row carries before its first
  # DB round-trip deserializes the jsonb value into a Hash.
  def merge_metadata!(hash)
    current = metadata
    if current.is_a?(String)
      current = begin
        JSON.parse(current)
      rescue JSON::ParserError, TypeError
        {}
      end
    end
    update!(metadata: (current || {}).merge(hash.compact.stringify_keys))
  end

  def mark_failed!(message)
    update!(status: "failed", error: message.to_s.truncate(1000))
  end
end
