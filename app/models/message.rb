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
  delegate :agent, to: :conversation, allow_nil: true

  enum :role, { user: "user", assistant: "assistant", system: "system", tool: "tool" }

  validates :role, presence: true
  validates :content, presence: true, unless: -> { tool_calls.present? }

  normalizes :content, with: ->(c) { c.to_s.strip }

  scope :chronological, -> { order(:created_at) }

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
