module ApplicationCable
  class Channel < ActionCable::Channel::Base
    private

    def active_auth_session?
      auth = AuthSession.find_by(id: connection.current_auth_session_id)
      auth.present? && auth.user_id == connection.current_user&.id && auth.usable_for?(auth.user)
    end

    def close_inactive_session!
      stop_all_streams
      connection.close(reason: "session_revoked", reconnect: false)
    end
  end
end
