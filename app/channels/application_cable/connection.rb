module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
      logger.add_tags "ActionCable", "User #{current_user.id}"
    end

    private

    def find_verified_user
      if (user = env["rack.session"]&.dig("user_id") ? User.find_by(id: env["rack.session"]["user_id"]) : nil)
        user
      elsif (token = request.params[:token])
        User.find_by(remember_token: token)
      else
        reject_unauthorized_connection
      end
    end
  end
end
