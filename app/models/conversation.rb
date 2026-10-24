# == Schema Information
#
# Table name: conversations
#
#  id             :uuid             not null, primary key
#  user_id        :uuid             not null
#  agent_id       :uuid             not null
#  title          :string
#  status         :string           default("active"), not null
#  metadata       :jsonb            default({}), not null
#  messages_count :integer          default(0), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
class Conversation < ApplicationRecord
  belongs_to :agent, touch: true
  belongs_to :user
  belongs_to :project, optional: true, touch: true

  has_many :messages, dependent: :destroy_async, inverse_of: :conversation
  has_many :runs, dependent: :nullify
  has_many :agent_runs, dependent: :destroy

  enum :status, { active: "active", archived: "archived" }, default: :active

  validates :title, length: { maximum: 200 }

  # counter_cache :messages_count on messages

  scope :recent, -> { order(updated_at: :desc) }

  # ── Phase 1: search + sidebar history ──────────────────────────────────
  # All query logic lives here (never in controllers/views). `search` powers
  # the ⌘K modal's GET /conversations/search endpoint; `sidebar_history` powers
  # the recency-grouped list in the app shell. Both are hard-scoped to the
  # owner and to active conversations.
  def self.ransackable_attributes(_auth_object = nil)
    %w[title status created_at updated_at]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[agent messages]
  end

  def self.search(user, query, limit: 25)
    scope = user.conversations.where(status: "active").includes(:agent)
    term = query.to_s.strip
    return scope.order(updated_at: :desc).limit(limit) if term.blank?

    scope.ransack(title_i_cont: term).result(distinct: true)
         .order(updated_at: :desc).limit(limit)
  end

  def self.sidebar_history(user, limit: 30)
    user.conversations.where(status: "active")
        .order(updated_at: :desc).includes(:agent).limit(limit)
  end

  after_create :increment_organization_counter
  after_destroy :decrement_organization_counter

  private

  def increment_organization_counter
    agent.organization.increment!(:conversations_count)
  end

  def decrement_organization_counter
    agent.organization.decrement!(:conversations_count) if agent&.organization
  end

  public

  # Methods.
  def latest_message
    messages.order(created_at: :desc).first
  end

  def total_tokens
    messages.sum(:tokens)
  end

  def generate_title
    return if title.present?
    first_user_message = messages.where(role: "user").first
    return unless first_user_message
    content = first_user_message.content.to_s
    self.title = content.truncate(50, omission: "...")
    save!
  end

  def archive!
    update!(status: "archived")
  end

  def resume!
    update!(status: "active")
  end

  def context_messages
    messages.where(role: %w[user assistant system])
      .order(created_at: :asc)
      .limit(50)
      .reject { |m| placeholder_assistant?(m) }
      .map(&:to_llm_hash)
  end

  # Assistant rows that carry no real payload must never enter the LLM
  # context window: streaming placeholders (metadata.streaming), blank
  # content, and legacy "." / ".." / "..." rows created by the pre-fix
  # code path all qualify. When in doubt, prefer dropping — a stray dot
  # in history confuses models far more than a skipped turn.
  def placeholder_assistant?(message)
    return false unless message.role == "assistant"
    return true if message.respond_to?(:streaming?) && message.streaming?
    stripped = message.content.to_s.strip
    return true if stripped.empty?
    [ ".", "..", "..." ].include?(stripped)
  end
end
