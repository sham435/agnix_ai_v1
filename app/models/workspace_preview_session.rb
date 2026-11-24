class WorkspacePreviewSession < ApplicationRecord
  DEFAULT_TTL = 30.minutes
  MAX_LIFETIME = 6.hours

  belongs_to :workspace

  validates :port, inclusion: { in: 1024..65535 }
  validates :token, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
  scope :for_workspace, ->(workspace) { where(workspace: workspace) }

  class << self
    def issue!(workspace:, port:)
      now = Time.current
      # One live session per workspace: an old link stops working the moment a
      # new preview starts, so a stale URL cannot outlive the server it pointed at.
      workspace.preview_sessions.where(revoked_at: nil).update_all(revoked_at: now)
      create!(
        workspace: workspace,
        port: port,
        token: SecureRandom.urlsafe_base64(24),
        expires_at: now + ttl.minutes
      )
    end

    def ttl
      minutes = Integer(ENV.fetch("SHAMS_WS_PREVIEW_TTL_MINUTES", DEFAULT_TTL / 1.minute))
      minutes.clamp(1, MAX_LIFETIME / 1.minute)
    end

    # The only lookup the gateway uses: the token must match, belong to the
    # workspace in the URL, and still be live.
    def resolve(token:, workspace:)
      session = find_by(token: token.to_s, workspace: workspace)
      session&.active? ? session : nil
    end
  end

  def active?
    revoked_at.nil? && expires_at > Time.current
  end

  def seconds_left
    [ (expires_at - Time.current).round, 0 ].max
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked_at?
  end

  def note_request!
    increment!(:request_count)
  end

  def path_for(sub_path = "")
    "/workspaces/#{workspace_id}/preview/#{port}/#{sub_path.to_s.sub(%r{\A/+}, "")}"
  end

  # Entry point for the gateway: the bare preview route plus this session's token.
  def gateway_path
    "/workspaces/#{workspace_id}/preview/#{port}?session=#{token}"
  end
end
