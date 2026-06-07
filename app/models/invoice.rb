# == Schema Information
#
# Table name: invoices
#
#  id               :uuid             not null, primary key
#  organization_id  :uuid             not null
#  stripe_id        :string           not null
#  amount           :integer
#  currency         :string           default("usd")
#  status           :string           default("draft")
#  hosted_invoice_url :string
#  invoice_pdf      :string
#  period_start     :datetime
#  period_end       :datetime
#  paid_at          :datetime
#  metadata         :jsonb            default({})
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class Invoice < ApplicationRecord
  belongs_to :organization

  enum :status, { draft: "draft", open: "open", paid: "paid", void: "void" }, default: :draft

  validates :stripe_id, presence: true, uniqueness: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Scopes.
  scope :paid, -> { where(status: "paid") }
  scope :unpaid, -> { where.not(status: "paid") }

  # Methods.
  def paid?
    status == "paid"
  end

  def amount_dollars
    return 0 unless amount
    amount / 100.0
  end
end
