class Workspace < ApplicationRecord
  RUNTIMES = %w[python3].freeze
  STATES = %w[pending ready stopped failed destroyed].freeze

  belongs_to :user
  belongs_to :conversation, optional: true
  has_many :runs, class_name: "WorkspaceRun", dependent: :destroy
  has_many :preview_sessions, class_name: "WorkspacePreviewSession", dependent: :destroy

  validates :runtime, inclusion: { in: RUNTIMES }
  validates :state, inclusion: { in: STATES }
  validates :name, presence: true, length: { maximum: 120 }

  scope :alive, -> { where(state: %w[pending ready stopped]) }
  scope :for_user, ->(user) { where(user: user) }

  # The manager keys containers and volumes by this uuid, so an agent tool can
  # only ever name a workspace the API already handed back.
  def manager_id
    id
  end

  def ready?
    state == "ready"
  end

  def live?
    %w[ready stopped].include?(state)
  end

  def record_state!(new_state, error: nil)
    stopped = new_state == "destroyed"
    update!(state: new_state,
            destroyed_at: (stopped ? (destroyed_at || Time.current) : nil),
            last_error: error && error.to_s.truncate(800))
  end
end
