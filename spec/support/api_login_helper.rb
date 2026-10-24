# frozen_string_literal: true

# Sign in through the real session endpoint for request specs, then fetch a
# real CSRF token (mirroring the browser client, which sends X-CSRF-Token on
# unsafe requests).
module ApiLoginHelper
  def api_login(user, password: "password123")
    post "/api/v1/sessions", params: { email: user.email, password: password }

    get "/api/v1/csrf"
    @api_csrf_token = JSON.parse(response.body)["token"]
  end

  def api_headers
    { "X-CSRF-Token" => @api_csrf_token.presence || fetch_csrf_token, "ACCEPT" => "application/json" }
  end

  private

  def fetch_csrf_token
    get "/api/v1/csrf"
    JSON.parse(response.body)["token"]
  end
end

RSpec.configure { |c| c.include ApiLoginHelper, type: :request }
