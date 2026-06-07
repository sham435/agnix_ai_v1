# Be sure to restart your server when you modify this file.

# ActiveSupport::CurrentAttributes.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :organization, :request_id
end
