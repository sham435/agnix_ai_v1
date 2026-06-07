# == Schema Information
#
# Table name: memberships
#
#  id              :uuid             not null, primary key
#  user_id         :uuid             not null
#  organization_id :uuid             not null
#  role            :string           default("member"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  enum :role, { member: "member", admin: "admin", owner: "owner" }, default: :member

  validates :user_id, uniqueness: { scope: :organization_id }

  delegate :name, :email, to: :user, prefix: true
end
