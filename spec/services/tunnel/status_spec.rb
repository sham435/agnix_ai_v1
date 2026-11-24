require "rails_helper"
require "tempfile"

RSpec.describe Tunnel::Status do
  subject(:status) { described_class.new(state_path: file.path).call }

  let(:file) { Tempfile.new("tunnel-status") }
  let(:url) { "https://verified-test-tunnel.trycloudflare.com" }


  before do
    file.write(url)
    file.flush
  end

  after { file.close! }

  it "verifies the published URL without claiming worker health" do
    stub_request(:get, "#{url}/login").to_return(status: 200)
    expect(status).to include(status: "degraded", verified_url: url, web_service_health: "healthy", worker_service_health: "unknown")
  end

  it "rejects an untrusted address without a network request" do
    file.rewind
    file.truncate(0)
    file.write("https://127.0.0.1")
    file.flush
    expect(status).to include(verified_url: nil, error_code: "invalid_supervisor_url")
  end

  it "rejects stale published state" do
    File.utime(2.days.ago.to_time, 2.days.ago.to_time, file.path)
    expect(status[:error_code]).to eq("stale_supervisor_url")
  end

  it "does not follow redirects" do
    stub_request(:get, "#{url}/login").to_return(status: 301, headers: { "Location" => "http://127.0.0.1" })
    expect(status).to include(verified_url: nil, error_code: "public_route_unhealthy")
  end

  it "returns a safe unavailable response for a timeout" do
    stub_request(:get, "#{url}/login").to_timeout
    expect(status).to include(status: "unavailable", verified_url: nil, error_code: "supervisor_verification_unavailable")
  end

  it "rereads external URL changes on each refresh" do
    File.write(file.path, "https://changed-test-tunnel.trycloudflare.com")
    stub_request(:get, "https://changed-test-tunnel.trycloudflare.com/login").to_return(status: 200)
    expect(status[:verified_url]).to eq("https://changed-test-tunnel.trycloudflare.com")
  end
end
