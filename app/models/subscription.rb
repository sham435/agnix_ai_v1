# == Schema Information
#
# Table name: subscriptions
#
#  id                     :uuid             not null, primary key
#  organization_id        :uuid             not null
#  stripe_id              :string           not null
#  stripe_price_id        :string
#  status                 :string           default("incomplete"), not null
#  current_period_start   :datetime
#  current_period_end     :datetime
#  cancel_at_period_end   :boolean          default(FALSE)
#  canceled_at            :datetime
#  metadata               :jsonb            default({})
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
class Subscription < ApplicationRecord
  belongs_to :organization

  enum :status, { incomplete: "incomplete", active: "active", past_due: "past_due", canceled: "canceled" }, default: :incomplete

  validates :stripe_id, presence: true, uniqueness: true

  # Scopes.
  scope :active, -> { where(status: "active") }
  scope :trialing, -> { where(status: "active") }
  scope :canceled, -> { where(status: "canceled") }

  # Methods.
  def active?
    status == "active"
  end

  def on_trial?
    status == "active" && current_period_start && Time.current < current_period_start + 14.days
  end
end
