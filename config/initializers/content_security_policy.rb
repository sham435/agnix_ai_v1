# Be sure to restart your server when you modify this file.

# Content Security Policy.
Rails.application.config.content_security_policy do |policy|
  policy.default_src :self, :https
  policy.font_src    :self, :https, :data
  policy.img_src     :self, :https, :data
  policy.object_src  :none
  policy.script_src  :self, :https, :unsafe_inline
  policy.style_src   :self, :https, :unsafe_inline
  policy.connect_src :self, :https, "https://api.openai.com", "https://api.anthropic.com", "wss:"
  policy.media_src   :self
  policy.frame_src   :self, "https://*.stripe.com"

  # Specify URI for violation reports
  # policy.report_uri "/csp-violation-report-endpoint"
end

# Generate session nonces for permitted importmap.
Rails.application.config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
Rails.application.config.content_security_policy_nonce_directives = %w[script-src style-src]

# Report violations without enforcing in development.
if Rails.env.development?
  Rails.application.config.content_security_policy_report_only = true
end
