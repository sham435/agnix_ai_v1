# WhatsApp Cloud API Service.
# Handles inbound/outbound messages, webhook verification.
# Sources:
#   - https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks
#   - https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-messages
class WhatsappService
  BASE_URL = "https://graph.facebook.com/v20.0"

  class << self
    # Verify webhook subscription.
    def verify_webhook(mode:, token:, challenge:)
      verify_token = Rails.application.credentials.dig(:whatsapp, :verify_token) || ENV.fetch("WHATSAPP_VERIFY_TOKEN", "")

      return nil unless mode == "subscribe" && token == verify_token
      challenge
    end

    # Handle incoming webhook payload.
    def handle_webhook(payload)
      data = JSON.parse(payload) if payload.is_a?(String)
      data = payload if data.is_a?(Hash)

      results = []

      # Process messages.
      if data["entry"]
        data["entry"].each do |entry|
          if entry["changes"]
            entry["changes"].each do |change|
              next unless change["value"]["messages"]
              change["value"]["messages"].each do |message|
                results << process_inbound_message(message, change["value"])
              end
            end
          end
        end
      end

      # Process statuses (delivered, read, etc).
      if data["entry"]
        data["entry"].each do |entry|
          if entry["changes"]
            entry["changes"].each do |change|
              next unless change["value"]["statuses"]
              change["value"]["statuses"].each do |status|
                process_status_update(status)
              end
            end
          end
        end
      end

      results
    end

    # Send a text message.
    def send_message(phone_number, text, reply_to_message_id: nil)
      phone_id = phone_number_id
      access_token = access_token
      return { error: "WhatsApp not configured" } unless phone_id && access_token

      body = {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: phone_number,
        type: "text",
        text: { body: text }
      }
      body[:context] = { message_id: reply_to_message_id } if reply_to_message_id

      response = HTTParty.post("#{BASE_URL}/#{phone_id}/messages",
        headers: {
          "Authorization" => "Bearer #{access_token}",
          "Content-Type" => "application/json"
        },
        body: body.to_json
      )

      if response.success?
        JSON.parse(response.body)
      else
        Rails.logger.error "WhatsApp send error: #{response.code} - #{response.body}"
        { error: "Failed to send message" }
      end
    end

    # Send a template message.
    def send_template(phone_number, template_name, language_code: "en", components: [])
      phone_id = phone_number_id
      access_token = access_token
      return { error: "WhatsApp not configured" } unless phone_id && access_token

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

      response = HTTParty.post("#{BASE_URL}/#{phone_id}/messages",
        headers: {
          "Authorization" => "Bearer #{access_token}",
          "Content-Type" => "application/json"
        },
        body: body.to_json
      )

      response.success? ? JSON.parse(response.body) : { error: response.body }
    end

    # Send a media message.
    def send_media(phone_number, media_url, caption: nil)
      phone_id = phone_number_id
      access_token = access_token
      return { error: "WhatsApp not configured" } unless phone_id && access_token

      body = {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: phone_number,
        type: "image",
        image: { link: media_url }
      }
      body[:image][:caption] = caption if caption

      response = HTTParty.post("#{BASE_URL}/#{phone_id}/messages",
        headers: {
          "Authorization" => "Bearer #{access_token}",
          "Content-Type" => "application/json"
        },
        body: body.to_json
      )

      response.success? ? JSON.parse(response.body) : { error: response.body }
    end

    # Find or create a user from a WhatsApp message.
    def find_or_create_user(phone_number, name: nil)
      user = User.find_by(whatsapp_phone: phone_number)
      return user if user

      # Create a new user if auto-provisioning is enabled.
      if Rails.application.credentials.dig(:whatsapp, :auto_provision)
        User.create!(
          email: "#{phone_number}@whatsapp.agnix.local",
          name: name || "WhatsApp User #{phone_number}",
          whatsapp_phone: phone_number,
          password: SecureRandom.hex(16),
          role: "user"
        )
      end

      nil
    end

    private

    def process_inbound_message(message, value)
      phone_number = value["contacts"]&.first&.dig("wa_id")
      user = find_or_create_user(phone_number, name: value["contacts"]&.first&.dig("profile", "name"))

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

      {
        phone_number: phone_number,
        user: user,
        content: content,
        message_id: message["id"],
        timestamp: message["timestamp"]
      }
    end

    def process_status_update(status)
      message_id = status["id"]
      whatsapp_status = status["status"] # sent, delivered, read, failed

      Rails.logger.info "WhatsApp message #{message_id} status: #{whatsapp_status}"
      # Update conversation messages if needed.
    end

    def phone_number_id
      Rails.application.credentials.dig(:whatsapp, :phone_number_id) || ENV.fetch("WHATSAPP_PHONE_NUMBER_ID", "")
    end

    def access_token
      Rails.application.credentials.dig(:whatsapp, :access_token) || ENV.fetch("WHATSAPP_ACCESS_TOKEN", "")
    end
  end
end
