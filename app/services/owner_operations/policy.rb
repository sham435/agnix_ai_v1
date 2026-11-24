module OwnerOperations
  class Policy
    MFA_MAX_AGE = 12.hours

    def self.allowed?(user:, organization:, auth_session:, session:)
      return false unless user && organization && auth_session
      return false unless auth_session.user_id == user.id && auth_session.usable_for?(user)
      return false unless organization.id.to_s == ENV["SHAMS_PLATFORM_ORGANIZATION_ID"].presence
      return false unless organization.owner_id == user.id && user.owner?(organization)
      return false unless user.second_factor_enabled?
      return false unless session[:mfa_auth_digest] == auth_session.token_digest

      verified_at = Time.iso8601(session[:mfa_verified_at].to_s)
      verified_at >= MFA_MAX_AGE.ago && verified_at <= Time.current && verified_at >= auth_session.created_at.change(usec: 0)
    rescue ArgumentError
      false
    end
  end
end
