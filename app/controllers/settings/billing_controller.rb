class Settings::BillingController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!

  def index
    @subscription = current_organization.subscriptions.order(created_at: :desc).first
    @invoices = current_organization.invoices.order(created_at: :desc).limit(10)
    @usage = StripeService.usage_summary(current_organization.id)
  end
end
