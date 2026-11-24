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

  # A running row's updated_at is its lease timestamp. This is deliberately
  # well beyond the provider's 60-second read timeout: recovery must never race
  # a legitimate generation, and it must never repeat a possibly billed POST.
  RUNNING_LEASE = 15.minutes
  STALE_RUNNING_ERROR = "Image generation was interrupted before completion. " \
                        "The provider may have charged for it; retry only deliberately."

  # Queued or running: blocks a second in-chat generation for the same
  # conversation and renders a skeleton in the gallery.
  scope :in_flight, -> { where(status: %w[queued running]) }
  scope :for_conversation, ->(conversation_id) {
    where("metadata->>'conversation_id' = ?", conversation_id.to_s)
  }

  # Single source of truth for the gallery subscription and worker broadcast.
  # Rendered cards contain private prompts and download URLs, so the stream is
  # always scoped to the generation owner rather than shared application-wide.
  def self.gallery_stream_name(user)
    "image_generations:#{user.id}"
  end

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

  # Fresh or legacy rows can carry raw JSON strings instead of a deserialized
  # Hash. Malformed JSON and non-object values behave as empty metadata.
  def normalized_metadata
    value = metadata
    value = JSON.parse(value) if value.is_a?(String)
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError, TypeError
    {}
  end

  # Merge provider detail / chat linkage into the jsonb metadata.
  def merge_metadata!(hash)
    update!(metadata: normalized_metadata.merge(hash.compact.stringify_keys))
  end

  def retry_available?
    return false if queued? || running?

    retry_at = normalized_metadata["retry_at"]
    retry_at.blank? || Time.iso8601(retry_at) <= Time.current
  end

  # Reload under lock so stale deliveries cannot both claim a billable request.
  def claim!
    with_lock do
      return false unless queued?

      update!(status: "running", error: nil)
      true
    end
  end

  # A hard-killed worker leaves no terminal transition. Only a redelivery may
  # close an expired lease, under the same row lock used by claim!, and recovery
  # never submits another provider request. Manual regenerate creates a new row.
  def recover_stale_running!
    with_lock do
      return false unless running? && updated_at <= RUNNING_LEASE.ago

      mark_failed!(STALE_RUNNING_ERROR, metadata: { "recovered_stale_at" => Time.current.utc.iso8601 })
      true
    end
  end

  def mark_failed!(message, metadata: {})
    update!(status: "failed", error: message.to_s.truncate(1000),
            metadata: normalized_metadata.merge(metadata.compact.stringify_keys))
  end
end
