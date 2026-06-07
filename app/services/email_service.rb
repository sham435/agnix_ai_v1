# Email Service - Transactional emails via Postmark.
class EmailService
  class << self
    def send_welcome_email(user)
      Postmark::ApiClient.new(
        Rails.application.credentials.dig(:postmark, :api_token)
      ).deliver_mail_with_template({
        From: "Shams <hello@agnix.ai>",
        To: user.email,
        TemplateAlias: "welcome",
        TemplateModel: {
          name: user.name,
          login_url: Rails.application.routes.url_helpers.login_url
        }
      })
    end

    def send_password_reset(user, token)
      Postmark::ApiClient.new(
        Rails.application.credentials.dig(:postmark, :api_token)
      ).deliver_mail_with_template({
        From: "Shams <hello@agnix.ai>",
        To: user.email,
        TemplateAlias: "password-reset",
        TemplateModel: {
          name: user.name,
          reset_url: Rails.application.routes.url_helpers.password_reset_url(token: token)
        }
      })
    end

    def send_invoice_email(user, invoice)
      Postmark::ApiClient.new(
        Rails.application.credentials.dig(:postmark, :api_token)
      ).deliver_mail_with_template({
        From: "Shams <billing@agnix.ai>",
        To: user.email,
        TemplateAlias: "invoice",
        TemplateModel: {
          name: user.name,
          amount: invoice.amount_dollars,
          invoice_url: invoice.hosted_invoice_url
        }
      })
    end

    def send_usage_alert(organization, tokens_used, threshold_percent)
      owner = organization.owner
      Postmark::ApiClient.new(
        Rails.application.credentials.dig(:postmark, :api_token)
      ).deliver_mail_with_template({
        From: "Shams <alerts@agnix.ai>",
        To: owner.email,
        TemplateAlias: "usage-alert",
        TemplateModel: {
          name: owner.name,
          org_name: organization.name,
          tokens_used: tokens_used,
          threshold_percent: threshold_percent
        }
      })
    end
  end
end
