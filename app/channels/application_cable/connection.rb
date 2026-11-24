module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_auth_session_id

    def connect
      self.current_user = find_verified_user
      logger.add_tags "ActionCable", "User #{current_user.id}"
    end

    private

    def find_verified_user
      user = User.find_by(id: cookies.signed[:user_id])
      auth = AuthSession.find_by_token(cookies.signed[:auth_token])
      if user && auth&.user_id == user.id && auth.usable_for?(user)
        self.current_auth_session_id = auth.id
        user
      else
        reject_unauthorized_connection
      end
    end
  end
end
