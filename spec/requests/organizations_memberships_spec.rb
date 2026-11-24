# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

RSpec.describe "Organization membership owner protection", type: :request do
  let(:owner) { create(:user) }
  let(:organization) { create(:organization, owner: owner) }
  let!(:owner_membership) { create(:membership, user: owner, organization: organization, role: "owner") }
  let(:admin) { create(:user) }
  let!(:admin_membership) { create(:membership, :admin, user: admin, organization: organization) }
  let(:member) { create(:user) }
  let!(:member_membership) { create(:membership, user: member, organization: organization) }
  let(:html_headers) { { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" } }

  context "when signed in as a plain member" do
    before { api_login(member) }

    it "cannot list organization members" do
      get organization_memberships_path(organization), headers: html_headers

      expect(response).to redirect_to(organization_path(organization))
      expect(flash[:alert]).to eq("Admin access required.")
    end

    it "cannot add a member" do
      invitee = create(:user)

      expect do
        post organization_memberships_path(organization),
             params: { email: invitee.email, role: "member" },
             headers: html_headers
      end.not_to change(Membership, :count)

      expect(response).to redirect_to(organization_path(organization))
    end

    it "cannot change its own role" do
      patch organization_membership_path(organization, member_membership),
            params: { membership: { role: "admin" } },
            headers: html_headers

      expect(response).to redirect_to(organization_path(organization))
      expect(member_membership.reload.role).to eq("member")
    end

    it "cannot remove another member" do
      delete organization_membership_path(organization, admin_membership), headers: html_headers

      expect(response).to redirect_to(organization_path(organization))
      expect(admin_membership.reload).to be_persisted
    end
  end

  context "when signed in as an admin" do
    before { api_login(admin) }

    it "cannot promote itself to owner through nested params" do
      patch organization_membership_path(organization, admin_membership),
            params: { membership: { role: "owner" } },
            headers: html_headers

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(flash[:alert]).to eq("Only member and admin roles can be assigned.")
      expect(admin_membership.reload.role).to eq("admin")
      expect(organization.reload.owner).to eq(owner)
    end

    it "cannot promote itself to owner through the legacy top-level param" do
      patch organization_membership_path(organization, admin_membership),
            params: { role: "owner" },
            headers: html_headers

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(admin_membership.reload.role).to eq("admin")
      expect(organization.reload.owner).to eq(owner)
    end

    it "cannot demote the organization owner" do
      patch organization_membership_path(organization, owner_membership),
            params: { membership: { role: "admin" } },
            headers: html_headers

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(flash[:alert]).to eq("Role cannot be changed for the organization owner")
      expect(owner_membership.reload.role).to eq("owner")
      expect(organization.reload.owner).to eq(owner)
    end

    it "cannot remove the organization owner" do
      delete organization_membership_path(organization, owner_membership), headers: html_headers

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(flash[:alert]).to eq("Organization owners cannot be removed")
      expect(owner_membership.reload).to be_persisted
      expect(organization.reload.owner).to eq(owner)
    end

    it "cannot add an owner without a target-consent workflow" do
      invitee = create(:user)

      expect do
        post organization_memberships_path(organization),
             params: { email: invitee.email, role: "owner" },
             headers: html_headers
      end.not_to change(Membership, :count)

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(flash[:alert]).to eq("Only member and admin roles can be assigned.")
    end

    it "rejects an unknown role instead of raising an enum error" do
      expect do
        patch organization_membership_path(organization, member_membership),
              params: { membership: { role: "superuser" } },
              headers: html_headers
      end.not_to raise_error

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(flash[:alert]).to eq("Only member and admin roles can be assigned.")
      expect(member_membership.reload.role).to eq("member")
    end

    it "still adds a regular member" do
      invitee = create(:user)

      expect do
        post organization_memberships_path(organization),
             params: { email: invitee.email, role: "member" },
             headers: html_headers
      end.to change { organization.memberships.where(user: invitee).count }.from(0).to(1)

      expect(organization.memberships.find_by!(user: invitee).role).to eq("member")
    end

    it "still adds an admin" do
      invitee = create(:user)

      post organization_memberships_path(organization),
           params: { email: invitee.email, role: "admin" },
           headers: html_headers

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(organization.memberships.find_by!(user: invitee).role).to eq("admin")
    end

    it "still promotes and demotes between member and admin" do
      patch organization_membership_path(organization, member_membership),
            params: { membership: { role: "admin" } },
            headers: html_headers
      expect(member_membership.reload.role).to eq("admin")

      patch organization_membership_path(organization, admin_membership),
            params: { role: "member" },
            headers: html_headers
      expect(admin_membership.reload.role).to eq("member")
    end

    it "still removes a non-owner member" do
      expect do
        delete organization_membership_path(organization, member_membership), headers: html_headers
      end.to change(Membership, :count).by(-1)

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(Membership.where(id: member_membership.id)).to be_empty
    end

    it "does not render owner as an assignable role or expose owner controls" do
      get organization_memberships_path(organization), headers: html_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(<option value="owner">))
      expect(response.body).not_to include(organization_membership_path(organization, owner_membership))
      expect(response.body).to include("Owner")
    end
  end

  context "when creating an organization" do
    it "still bootstraps the creator as the initial owner" do
      creator = create(:user)
      api_login(creator)

      expect do
        post organizations_path,
             params: { organization: { name: "H4 Bootstrap", slug: "h4-bootstrap" } },
             headers: html_headers
      end.to change(Organization, :count).by(1)

      created = Organization.find_by!(slug: "h4-bootstrap")
      expect(created.owner).to eq(creator)
      expect(created.memberships.find_by!(user: creator).role).to eq("owner")
    end
  end

  context "when signed in as the organization owner" do
    before { api_login(owner) }

    it "cannot grant owner through the add form even with owner authorization" do
      invitee = create(:user)

      expect do
        post organization_memberships_path(organization),
             params: { email: invitee.email, role: "owner" },
             headers: html_headers
      end.not_to change(Membership, :count)

      expect(flash[:alert]).to eq("Only member and admin roles can be assigned.")
    end

    it "cannot grant owner through a role update without target consent" do
      patch organization_membership_path(organization, member_membership),
            params: { membership: { role: "owner" } },
            headers: html_headers

      expect(response).to redirect_to(organization_memberships_path(organization))
      expect(member_membership.reload.role).to eq("member")
    end

    it "still adds an admin and removes a non-owner member" do
      invitee = create(:user)
      post organization_memberships_path(organization),
           params: { email: invitee.email, role: "admin" },
           headers: html_headers
      invitee_membership = organization.memberships.find_by!(user: invitee)
      expect(invitee_membership.role).to eq("admin")

      delete organization_membership_path(organization, member_membership), headers: html_headers
      expect(Membership.where(id: member_membership.id)).to be_empty
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
