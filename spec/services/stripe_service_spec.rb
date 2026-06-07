require "rails_helper"

RSpec.describe StripeService, type: :service do
  let(:organization) { create(:organization, plan: "pro") }

  describe ".handle_webhook" do
    let(:payload) { '{"type": "invoice.payment_succeeded", "data": {"object": {"id": "in_test", "amount_due": 1000, "currency": "usd", "status": "paid", "hosted_invoice_url": "https://invoice.stripe.com/test", "period_start": 1704067200, "period_end": 1706745600, "status_transitions": {"paid_at": 1704067200}}}}' }
    let(:signature) { "test_signature" }

    before do
      allow(Stripe::Webhook).to receive(:construct_event)
        .with(payload, signature, anything)
        .and_return(Stripe::Event.construct(JSON.parse(payload)))
    end

    it "creates an invoice record" do
      expect { StripeService.handle_webhook(payload, signature) }
        .to change { Invoice.count }.by(1)
    end

    it "creates an invoice with correct attributes" do
      StripeService.handle_webhook(payload, signature)
      invoice = Invoice.last
      expect(invoice.stripe_id).to eq("in_test")
      expect(invoice.amount).to eq(1000)
      expect(invoice.status).to eq("paid")
    end
  end

  describe ".usage_summary" do
    before do
      create_list(:usage_event, 3, organization: organization, tokens: 100, cost_cents: 30)
      create(:usage_event, organization: organization, tokens: 200, cost_cents: 60)
    end

    it "returns correct totals" do
      summary = StripeService.usage_summary(organization.id)
      expect(summary[:tokens_this_month]).to eq(500)
      expect(summary[:cost_this_month_cents]).to eq(150)
    end
  end
end
