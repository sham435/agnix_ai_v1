# Stripe Service - Handles billing, subscriptions, webhooks, and usage metering.
# Sources:
#   - https://docs.stripe.com/billing/subscriptions/webhooks
#   - https://cuebytes.com/blog/stripe-subscriptions-implementation-guide (2026)
class StripeService
  class << self
    # Create a Stripe Checkout session.
    def create_checkout_session(organization, price_id:, success_url:, cancel_url:)
      session = Stripe::Checkout::Session.create({
        customer: organization.stripe_customer_id || create_customer(organization),
        mode: "subscription",
        line_items: [{ price: price_id, quantity: 1 }],
        success_url: success_url,
        cancel_url: cancel_url,
        metadata: {
          organization_id: organization.id
        },
        subscription_data: {
          metadata: {
            organization_id: organization.id
          }
        }
      })

      { url: session.url, id: session.id, client_secret: session.client_secret }
    end

    # Create a Stripe billing portal session.
    def create_portal_session(organization, return_url:)
      customer_id = ensure_customer(organization)
      session = Stripe::BillingPortal::Session.create({
        customer: customer_id,
        return_url: return_url
      })

      { url: session.url }
    end

    # Handle Stripe webhook events.
    def handle_webhook(payload, signature)
      webhook_secret = Rails.application.config.stripe.webhook_secret
      event = Stripe::Webhook.construct_event(payload, signature, webhook_secret)

      case event.type
      when "checkout.session.completed"
        handle_checkout_completed(event.data.object)
      when "invoice.payment_succeeded"
        handle_invoice_succeeded(event.data.object)
      when "invoice.payment_failed"
        handle_invoice_failed(event.data.object)
      when "customer.subscription.created"
        handle_subscription_created(event.data.object)
      when "customer.subscription.updated"
        handle_subscription_updated(event.data.object)
      when "customer.subscription.deleted"
        handle_subscription_deleted(event.data.object)
      when "customer.subscription.trial_will_end"
        handle_trial_will_end(event.data.object)
      else
        Rails.logger.info "Unhandled Stripe event: #{event.type}"
      end

      event
    end

    # Create usage-based billing meter.
    def report_usage(organization_id, tokens:, cost_cents:, event_type: "chat_completion", run_id: nil)
      UsageEvent.create!(
        organization_id: organization_id,
        run_id: run_id,
        event_type: event_type,
        tokens: tokens,
        cost_cents: cost_cents,
        metadata: { reported_at: Time.current.iso8601 }
      )
    end

    # Get usage summary for an organization.
    def usage_summary(organization_id)
      {
        tokens_this_month: UsageEvent.total_tokens_this_month(organization_id),
        cost_this_month_cents: UsageEvent.total_cost_this_month(organization_id),
        events_by_type: UsageEvent.where(organization_id: organization_id)
          .this_month
          .group(:event_type)
          .sum(:tokens)
      }
    end

    # List available prices.
    def list_prices
      Stripe::Price.list(active: true, limit: 100)
    end

    # List products.
    def list_products
      Stripe::Product.list(active: true, limit: 100)
    end

    private

    def create_customer(organization)
      customer = Stripe::Customer.create({
        name: organization.name,
        metadata: {
          organization_id: organization.id
        }
      })
      organization.update!(stripe_customer_id: customer.id)
      customer.id
    end

    def ensure_customer(organization)
      organization.stripe_customer_id || create_customer(organization)
    end

    def handle_checkout_completed(session)
      org = Organization.find_by(id: session.metadata[:organization_id])
      return unless org

      Rails.logger.info "Checkout completed for organization #{org.id}"
    end

    def handle_invoice_succeeded(invoice)
      org = Organization.find_by(id: invoice.metadata[:organization_id])
      return unless org

      Invoice.find_or_create_by!(stripe_id: invoice.id) do |inv|
        inv.organization = org
        inv.amount = invoice.amount_due
        inv.currency = invoice.currency
        inv.status = "paid"
        inv.hosted_invoice_url = invoice.hosted_invoice_url
        inv.invoice_pdf = invoice.invoice_pdf
        inv.period_start = Time.at(invoice.period_start)
        inv.period_end = Time.at(invoice.period_end)
        inv.paid_at = Time.at(invoice.status_transitions[:paid_at]) if invoice.status_transitions[:paid_at]
      end
    end

    def handle_invoice_failed(invoice)
      inv = Invoice.find_by(stripe_id: invoice.id)
      inv&.update!(status: invoice.status)
    end

    def handle_subscription_created(subscription)
      org = Organization.find_by(id: subscription.metadata[:organization_id])
      return unless org

      Subscription.create!(
        organization: org,
        stripe_id: subscription.id,
        stripe_price_id: subscription.items.data.first.price.id,
        status: subscription.status,
        current_period_start: Time.at(subscription.current_period_start),
        current_period_end: Time.at(subscription.current_period_end),
        metadata: subscription.metadata
      )
    end

    def handle_subscription_updated(subscription)
      sub = Subscription.find_by(stripe_id: subscription.id)
      return unless sub

      sub.update!(
        status: subscription.status,
        stripe_price_id: subscription.items.data.first.price.id,
        current_period_start: Time.at(subscription.current_period_start),
        current_period_end: Time.at(subscription.current_period_end),
        cancel_at_period_end: subscription.cancel_at_period_end,
        canceled_at: subscription.canceled_at ? Time.at(subscription.canceled_at) : nil
      )
    end

    def handle_subscription_deleted(subscription)
      sub = Subscription.find_by(stripe_id: subscription.id)
      sub&.update!(status: "canceled", canceled_at: Time.current)
    end

    def handle_trial_will_end(subscription)
      Rails.logger.info "Trial will end for subscription #{subscription.id}"
    end
  end
end
