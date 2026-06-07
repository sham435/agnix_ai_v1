class BillingController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!

  def checkout
    price_id = params[:price_id]
    return redirect_to settings_billing_path, alert: "Price ID required." unless price_id

    result = StripeService.create_checkout_session(
      current_organization,
      price_id: price_id,
      success_url: settings_billing_url(success: true),
      cancel_url: settings_billing_url
    )

    redirect_to result[:url], allow_other_host: true
  end

  def portal
    result = StripeService.create_portal_session(
      current_organization,
      return_url: settings_billing_url
    )

    redirect_to result[:url], allow_other_host: true
  end
end
