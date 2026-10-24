# == Schema Information
#
# Table name: messages
#
#  id              :uuid             not null, primary key
#  conversation_id :uuid             not null
#  role            :string           not null
#  content         :text
#  tokens          :integer
#  tool_calls      :jsonb            default([])
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Message < ApplicationRecord
  belongs_to :conversation, counter_cache: true, touch: true
  has_many :message_attachments, dependent: :delete_all
  has_many :assets, through: :message_attachments
  delegate :agent, to: :conversation, allow_nil: true

  enum :role, { user: "user", assistant: "assistant", system: "system", tool: "tool" }

  validates :role, presence: true
  # Content may be blank in four legitimate cases:
  #   1. Tool-call-only assistant turns (tool_calls carries the payload).
  #   2. Attachment-only user turns (pending_attachment_asset_ids mirrors the
  #      inbound param because join rows are created after save).
  #   3. In-flight streaming placeholders — AgentStreamJob creates the
  #      assistant row before the first chunk arrives and flags it via
  #      metadata["streaming"]. Using "" (never ".") so no dot can leak into
  #      persisted history, LLM context, or rendered bubbles.
  #   4. Finalized empty responses — the provider returned nothing renderable
  #      and we marked the row with metadata["empty_response"] rather than
  #      fabricating an apology string.
  attr_accessor :pending_attachment_asset_ids
  validates :content, presence: true, unless: -> {
    tool_calls.present? ||
      pending_attachment_asset_ids.to_a.compact.present? ||
      streaming? ||
      empty_response?
  }

  normalizes :content, with: ->(c) { c.to_s.strip }

  scope :chronological, -> { order(:created_at) }

  MAX_ATTACHMENTS = 8

  # Streaming placeholder helpers — a message is "streaming" while
  # metadata["streaming"] == true; the flag is dropped when the run finishes.
  def streaming?
    metadata.is_a?(Hash) && metadata["streaming"] == true
  end

  # When the assistant placeholder was first broadcast (set by AgentStreamJob).
  # Legacy placeholders predate this field and return nil.
  def stream_started_at
    stamp = metadata.is_a?(Hash) ? metadata["stream_started_at"] : nil
    return nil if stamp.blank?

    Time.parse(stamp.to_s)
  rescue ArgumentError
    nil
  end

  # A streaming placeholder whose start stamp is present and older than the
  # execution timeout is "stale": the job crashed, was lost, or never finalized.
  # Rows with NO stamp are never stale, so genuine pre-existing in-flight runs
  # keep showing the live indicator after a refresh. This gives us honest
  # recovery without a background sweeper: a dead run stops rendering "thinking"
  # once its configured execution window has elapsed.
  STREAMING_TIMEOUT = 2.minutes

  def stale_streaming?
    return false unless streaming?

    started = stream_started_at
    return false if started.nil?

    Time.now.utc - started.utc > STREAMING_TIMEOUT
  end

  # Distinct state for provider returned nothing renderable.
  def empty_response?
    metadata.is_a?(Hash) && metadata["empty_response"] == true
  end

  # Attach canonical assets to this message. Only assets the acting user is
  # permitted to read are connected; anything else is ignored (defense in
  # depth — the upload is already owner-scoped by user_id + checksum).
  def attach_assets!(asset_ids, for_user:)
    ids = Array(asset_ids).first(MAX_ATTACHMENTS).map(&:to_s).uniq
    return true if ids.empty?

    assets = Asset.where(id: ids).select { |a| a.readable_by?(for_user) }
    assets.each { |a| message_attachments.where(asset: a).first_or_create! }
    true
  end

  def attachment_count
    message_attachments.size
  end

  # Store tool calls as jsonb, validate shape.
  validate :tool_calls_shape

  # Methods.
  def to_llm_hash
    hash = { role: role, content: content }
    hash[:tool_calls] = tool_calls if tool_calls.present? && role == "assistant"
    hash[:tool_call_id] = metadata["tool_call_id"] if role == "tool"
    hash
  end

  def user_message?
    role == "user"
  end

  def assistant_message?
    role == "assistant"
  end

  def has_tool_calls?
    tool_calls.present? && tool_calls.is_a?(Array) && tool_calls.any?
  end

  def estimate_tokens
    self.tokens ||= (content.to_s.length / 4.0).ceil
  end

  private

  def tool_calls_shape
    return if tool_calls.is_a?(Array)
    errors.add(:tool_calls, "must be array")
  end
end
