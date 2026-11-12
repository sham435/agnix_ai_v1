# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# `plan` is the billing state a paid tier would gate on, so it must only move
# when money moves — never from the organization settings form, which any org
# admin can open.

RSpec.describe "Organization plan", type: :request do
  let(:organization) { create(:organization) }
  let(:admin) { organization.owner }
  let(:html_headers) { { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" } }

  before do
    create(:membership, user: admin, organization: organization, role: "owner")
    api_login(admin)
  end

  it "leaves the plan untouched when the edit form posts one anyway" do
    patch organization_path(organization),
      params: { organization: { name: "Renamed Org", plan: "enterprise" } },
      headers: html_headers

    follow_redirect!
    expect(response.body).to include("Renamed Org")
    expect(organization.reload.plan).to eq("free")
  end

  it "renders no plan control in the edit form" do
    get edit_organization_path(organization), headers: html_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("organization[plan]")
  end

  it "refuses a plain member who posts a plan anyway" do
    member = create(:user)
    create(:membership, user: member, organization: organization)
    api_login(member)
    original_name = organization.name

    patch organization_path(organization),
      params: { organization: { name: "Taken Org", plan: "pro" } },
      headers: html_headers

    expect(organization.reload.name).to eq(original_name)
    expect(organization.plan).to eq("free")
  end
end
