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
  # There is no target-consent ownership transfer flow, so membership
  # management cannot grant owner privileges. Organization creation bootstraps
  # the initial owner directly.
  ASSIGNABLE_ROLES = %w[member admin].freeze

  belongs_to :user
  belongs_to :organization

  enum :role, { member: "member", admin: "admin", owner: "owner" }, default: :member

  validates :user_id, uniqueness: { scope: :organization_id }
  validate :owner_membership_must_belong_to_organization_owner
  validate :owner_role_immutable, if: :persisted?

  delegate :name, :email, to: :user, prefix: true

  def organization_owner?
    owner? || organization.owner_id == user_id
  end

  def destroy
    return reject_owner_removal if organization_owner? && !destroyed_by_association

    super
  end

  private

  def owner_membership_must_belong_to_organization_owner
    return unless owner?
    return if organization.owner_id == user_id

    errors.add(:role, "is reserved for the organization owner")
  end

  def owner_role_immutable
    return unless role_changed?
    return unless role_change.first == "owner" || role_change.last == "owner" || user_id == organization.owner_id

    errors.add(:role, "cannot be changed for the organization owner")
  end

  def reject_owner_removal
    errors.add(:base, "Organization owners cannot be removed")
    false
  end
end
