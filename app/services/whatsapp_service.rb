# WhatsApp Cloud API Service.
# Handles inbound/outbound messages, webhook verification.
# Sources:
#   - https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks
#   - https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
require "openssl"

class WhatsappService
  BASE_URL = "https://graph.facebook.com/v20.0"

  class << self
    # Verify webhook subscription.
    def verify_webhook(mode:, token:, challenge:)
      verify_token = whatsapp_config(:verify_token, "WHATSAPP_VERIFY_TOKEN")
      return nil if verify_token.blank?
      return nil unless mode == "subscribe" && token.present? &&
        ActiveSupport::SecurityUtils.secure_compare(token, verify_token)

      challenge.presence
    end

    def valid_signature?(payload, signature)
      app_secret = whatsapp_config(:app_secret, "WHATSAPP_APP_SECRET")
      return false if app_secret.blank? || signature.blank?

      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", app_secret, payload)}"
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    # Handle incoming webhook payload.
    def handle_webhook(payload)
      data = payload
      data = JSON.parse(data) if data.is_a?(String)
      return [] unless data.is_a?(Hash)

      results = []
      Array(data["entry"]).each do |entry|
        Array(entry["changes"]).each do |change|
          value = change["value"]
          next unless value.is_a?(Hash)

          integration = ToolIntegration.whatsapp_integration_for(value.dig("metadata", "phone_number_id"))
          if integration && value["messages"].present?
            value["messages"].each do |message|
              result = process_inbound_message(message, value, integration)
              next unless result

              results << result
              dispatch_inbound_message(result)
            end
          end

          Array(value["statuses"]).each { |status| process_status_update(status) }
        end
      end

      results
    end

    # Send a text message.
    def send_message(phone_number, text, reply_to_message_id: nil)
      phone_id = phone_number_id
      token = access_token
      return { error: "WhatsApp not configured" } unless phone_id.present? && token.present?

      body = {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: phone_number,
        type: "text",
        text: { body: text }
      }
      body[:context] = { message_id: reply_to_message_id } if reply_to_message_id

      send_payload(phone_id, token, body)
    end

    # Send a template message.
    def send_template(phone_number, template_name, language_code: "en", components: [])
      phone_id = phone_number_id
      token = access_token
      return { error: "WhatsApp not configured" } unless phone_id.present? && token.present?

      body = {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: phone_number,
        type: "template",
        template: {
          name: template_name,
          language: { code: language_code },
          components: components
        }
      }

      send_payload(phone_id, token, body)
    end

    # Send a media message.
    def send_media(phone_number, media_url, caption: nil)
      phone_id = phone_number_id
      token = access_token
      return { error: "WhatsApp not configured" } unless phone_id.present? && token.present?

      body = {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: phone_number,
        type: "image",
        image: { link: media_url }
      }
      body[:image][:caption] = caption if caption

      send_payload(phone_id, token, body)
    end

    # Find or create a user from a WhatsApp message.
    def find_or_create_user(phone_number, organization:, name: nil)
      user = User.find_by(whatsapp_phone: phone_number)
      return user if user && user.organizations.exists?(id: organization.id)
      return nil if user

      # Create a new user if auto-provisioning is enabled.
      return nil unless Rails.application.credentials.dig(:whatsapp, :auto_provision)

      user = User.create!(
        email: "#{phone_number}@whatsapp.shams.local",
        name: name || "WhatsApp User #{phone_number}",
        whatsapp_phone: phone_number,
        password: SecureRandom.hex(16),
        role: "user"
      )
      organization.add_user(user)
      user
    end

    private

    def send_payload(phone_id, token, body)
      response = HTTParty.post("#{BASE_URL}/#{phone_id}/messages",
        headers: {
          "Authorization" => "Bearer #{token}",
          "Content-Type" => "application/json"
        },
        body: body.to_json
      )

      if response.success?
        JSON.parse(response.body)
      else
        # Provider bodies and exception messages can echo message text or tokens.
        Rails.logger.error("WhatsApp send error: HTTP #{response.code.to_i}")
        { error: "Failed to send message" }
      end
    rescue StandardError => e
      Rails.logger.error("WhatsApp send error: #{e.class}")
      { error: "Failed to send message" }
    end

    def process_inbound_message(message, value, integration)
      phone_number = value["contacts"]&.first&.dig("wa_id")
      return nil if phone_number.blank?

      user = find_or_create_user(phone_number, organization: integration.organization,
        name: value["contacts"]&.first&.dig("profile", "name"))
      return nil unless user

      content = case message["type"]
      when "text"
        message.dig("text", "body")
      when "image"
        message.dig("image", "caption")
      when "document"
        message.dig("document", "caption")
      when "audio"
        "[Audio message]"
      when "video"
        "[Video message]"
      when "location"
        "Location: #{message.dig('location', 'latitude')}, #{message.dig('location', 'longitude')}"
      else
        "[Unsupported message type: #{message['type']}]"
      end
      return nil if content.blank?

      {
        phone_number: phone_number,
        user: user,
        organization: integration.organization,
        integration: integration,
        content: content,
        message_id: message["id"],
        timestamp: message["timestamp"]
      }
    end

    def dispatch_inbound_message(result)
      agent = Agent.chat_selection(result[:organization])
      return unless agent

      conversation = Conversation.find_or_create_by!(
        user: result[:user],
        agent: agent
      ) do |conv|
        conv.title = "WhatsApp Chat #{result[:phone_number]}"
      end

      source_message = conversation.messages.create!(role: "user", content: result[:content])
      AgentStreamJob.perform_later(
        conversation_id: conversation.id,
        user_id: result[:user].id,
        message_id: source_message.id,
        request_id: result[:message_id],
        message_content: result[:content],
        channel: :whatsapp,
        phone_number: result[:phone_number],
        whatsapp_integration_id: result[:integration].id
      )
    end

    def process_status_update(status)
      message_id = status["id"]
      whatsapp_status = status["status"] # sent, delivered, read, failed

      Rails.logger.info "WhatsApp message #{message_id} status: #{whatsapp_status}"
      # Update conversation messages if needed.
    end

    def whatsapp_config(key, env_key)
      Rails.application.credentials.dig(:whatsapp, key).presence || ENV[env_key].presence
    end

    def phone_number_id
      Rails.application.credentials.dig(:whatsapp, :phone_number_id) || ENV.fetch("WHATSAPP_PHONE_NUMBER_ID", "")
    end

    def access_token
      Rails.application.credentials.dig(:whatsapp, :access_token) || ENV.fetch("WHATSAPP_ACCESS_TOKEN", "")
    end
  end
end
