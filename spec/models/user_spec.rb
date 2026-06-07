require "rails_helper"

RSpec.describe User, type: :model do
  subject { build(:user) }

  it { is_expected.to validate_presence_of(:email) }
  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_presence_of(:password).on(:create) }
  it { is_expected.to have_many(:memberships).dependent(:destroy) }
  it { is_expected.to have_many(:organizations).through(:memberships) }
  it { is_expected.to have_many(:conversations).dependent(:destroy) }

  describe "#authenticate" do
    it "returns user with correct password" do
      user = create(:user, password: "securepassword")
      expect(user.authenticate("securepassword")).to eq(user)
    end

    it "returns false with wrong password" do
      user = create(:user, password: "securepassword")
      expect(user.authenticate("wrong")).to be_falsey
    end
  end

  describe "#admin?" do
    it "returns true for admin role" do
      user = create(:user, role: "admin")
      expect(user.admin?).to be true
    end

    it "returns false for user role" do
      user = create(:user, role: "user")
      expect(user.admin?).to be false
    end
  end
end
