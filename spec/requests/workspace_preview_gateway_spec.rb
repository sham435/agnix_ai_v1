# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

# The preview gateway is the only inbound door to a sandbox's HTTP server, so
# what it refuses matters more than what it serves. These specs pin the four
# gates — signed in, own workspace, live session token, pinned port — plus the
# two behaviours that make a real page work behind them: absolute asset URLs
# re-pointed at the preview path, and a path-scoped cookie so the css and js a
# link pulls in do not each have to carry the token.
#
# The manager is stubbed: its answer is a canned envelope, because these
# examples are about what this app is willing to forward. The live daemon
# round-trip is covered separately, against the real manager.
RSpec.describe "Workspace preview gateway", type: :request do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:workspace) { create(:workspace, user: user) }
  let(:preview) { create(:workspace_preview_session, workspace: workspace, port: 8000) }
  let(:prefix) { "/workspaces/#{workspace.id}/preview/8000" }

  def gateway_path(sub = "", query = {})
    path = sub.to_s.empty? ? prefix : "#{prefix}/#{sub.to_s.sub(%r{\A/+}, '')}"
    query.empty? ? path : "#{path}?#{Rack::Utils.build_query(query)}"
  end

  def visit_preview(sub = "", query: {}, method: "get", headers: {}, params: nil)
    uri = gateway_path(sub, query.transform_keys(&:to_s))
    args = { headers: headers }
    args[:params] = params if params
    public_send(method, uri, **args)
  end

  def stub_upstream(status: 200, response_headers: { "content-type" => [ "text/html; charset=utf-8" ] },
                    response_body: "")
    captured = []
    allow(Workspaces::ManagerClient).to receive(:raw) do |method, path, query: {}, headers: {}, body: nil|
      captured << { method: method, path: path, query: query, headers: headers, body: body }
      [ status, response_headers, response_body ]
    end
    captured
  end

  describe "browser isolation" do
    it "sandboxes direct previews without application-origin authority or caching" do
      api_login(user)
      stub_upstream(response_headers: {
        "content-type" => [ "text/html" ],
        "cache-control" => [ "public, max-age=86400" ],
        "content-security-policy" => [ "sandbox allow-same-origin allow-scripts" ]
      }, response_body: "<script>document.title = 'preview';</script>")

      get gateway_path("", "session" => preview.token)

      expect(response).to have_http_status(:ok)
      policy = response.headers.fetch("Content-Security-Policy")
      expect(policy).to include("sandbox allow-scripts allow-forms", "connect-src 'none'")
      expect(policy).not_to include("allow-same-origin", "allow-top-navigation")
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end
  end

  describe "the lifetime of an issued link" do
    it "expires after the TTL in minutes, and the link is the bare preview route" do
      issued = WorkspacePreviewSession.issue!(workspace: workspace, port: 8000)

      expect(issued.seconds_left).to be_within(2).of(WorkspacePreviewSession::DEFAULT_TTL)
      expect(issued.gateway_path).to eq("/workspaces/#{workspace.id}/preview/8000?session=#{issued.token}")
    end

    it "retires the link that was live before this one" do
      first = WorkspacePreviewSession.issue!(workspace: workspace, port: 8000)
      second = WorkspacePreviewSession.issue!(workspace: workspace, port: 8000)

      expect(first.reload).not_to be_active
      expect(second).to be_active
    end
  end

  describe "who may reach a preview" do
    it "sends an anonymous visitor to sign in" do
      get gateway_path("", "session" => preview.token)

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(login_path)
    end

    it "hides a workspace that belongs to someone else" do
      api_login(user)
      theirs = create(:workspace, user: other)
      theirs_preview = create(:workspace_preview_session, workspace: theirs)

      get "/workspaces/#{theirs.id}/preview/#{theirs_preview.port}?session=#{theirs_preview.token}"

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("no such workspace")
    end

    it "refuses a token issued for a different workspace" do
      api_login(user)
      foreign = create(:workspace_preview_session, workspace: create(:workspace, user: user))

      get gateway_path("", "session" => foreign.token)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a revoked session" do
      api_login(user)
      preview.revoke!

      visit_preview("", query: { "session" => preview.token })

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("not valid")
    end

    it "refuses an expired session" do
      api_login(user)
      preview.update!(expires_at: 1.second.ago)

      visit_preview("", query: { "session" => preview.token })

      expect(response).to have_http_status(:forbidden)
      expect(preview.reload.active?).to be false
    end

    it "refuses a port the session did not open" do
      api_login(user)
      allow(Workspaces::ManagerClient).to receive(:raw)

      get "/workspaces/#{workspace.id}/preview/9000?session=#{preview.token}"

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("opened port 8000")
      expect(Workspaces::ManagerClient).not_to have_received(:raw)
    end
  end

  describe "request body bounds" do
    it "reads only one byte past the cap when content length is absent" do
      body = StringIO.new("x" * (WorkspacePreviewsController::MAX_REQUEST_BYTES + 100))
      request = instance_double(ActionDispatch::Request, request_method: "POST", content_length: nil, body: body)
      controller = WorkspacePreviewsController.new
      allow(controller).to receive(:request).and_return(request)

      expect(controller.send(:request_body)).to eq(:too_large)
      expect(body.pos).to eq(WorkspacePreviewsController::MAX_REQUEST_BYTES + 1)
    end

    it "rejects an oversized declared body before reading it" do
      body = StringIO.new("small")
      request = instance_double(ActionDispatch::Request, request_method: "POST",
        content_length: WorkspacePreviewsController::MAX_REQUEST_BYTES + 1, body: body)
      controller = WorkspacePreviewsController.new
      allow(controller).to receive(:request).and_return(request)

      expect(controller.send(:request_body)).to eq(:too_large)
      expect(body.pos).to eq(0)
    end
  end

  describe "forwarding" do
    before { api_login(user) }

    it "serves the page, rebases absolute URLs and counts the request" do
      upstream = stub_upstream(response_body: %(<link href="/static/a.css"><img src="/logo.png"><a href="/about">x</a>))

      visit_preview("", query: { "session" => preview.token })

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="#{prefix}/static/a.css"))
      expect(response.body).to include(%(src="#{prefix}/logo.png"))
      expect(response.body).to include(%(href="#{prefix}/about"))
      expect(response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(upstream.first[:path]).to eq("/preview/#{workspace.id}/8000/")
      expect(preview.reload.request_count).to eq(1)
    end

    it "forwards a nested path and the visitor's query, but never the session token" do
      upstream = stub_upstream(response_body: "hi")

      visit_preview("static/a.css", query: { "session" => preview.token, "v" => "3" })

      expect(upstream.first[:path]).to eq("/preview/#{workspace.id}/8000/static/a.css")
      expect(upstream.first[:query]).to eq("v" => "3")
      expect(response.body).to eq("hi")
    end

    it "keeps a url that is already absolute out of the rewrite" do
      stub_upstream(response_body: %(<a href="https://example.com/in">in</a><a href="/out">out</a>))

      visit_preview("", query: { "session" => preview.token })

      expect(response.body).to include(%(href="https://example.com/in"))
      expect(response.body).to include(%(href="#{prefix}/out"))
    end

    it "rebases a css url() the same way" do
      stub_upstream(response_headers: { "content-type" => [ "text/css" ] },
                    response_body: "header{background:url(/static/hero.png) no-repeat}")

      visit_preview("static/a.css", query: { "session" => preview.token })

      expect(response.body).to include("url(#{prefix}/static/hero.png)")
    end

    it "hands a form post through without a CSRF token of ours" do
      upstream = stub_upstream(response_headers: { "content-type" => [ "text/html" ] }, response_body: "saved")

      visit_preview("contact", query: { "session" => preview.token },
                    method: "post", params: { "name" => "Azmika" })

      expect(response).to have_http_status(:ok)
      expect(upstream.first[:method]).to eq("POST")
      expect(upstream.first[:body]).to include("name=Azmika")
      expect(upstream.first[:headers]["Content-Type"]).to eq("application/x-www-form-urlencoded")
    end

    it "re-points a redirect the sandbox server issued" do
      stub_upstream(status: 302,
                    response_headers: { "content-type" => [ "text/html" ], "location" => [ "/about" ] })

      visit_preview("", query: { "session" => preview.token })

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq("#{prefix}/about")
    end

    it "keeps a path-relative redirect inside the preview" do
      stub_upstream(status: 302, response_headers: { "location" => [ "next?step=2" ] })

      visit_preview("start", query: { "session" => preview.token })

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq("next?step=2")
    end

    it "rejects absolute and protocol-relative external redirects" do
      [ "https://example.com/leave", "//example.com/leave" ].each do |location|
        stub_upstream(status: 302, response_headers: { "location" => [ location ] })

        visit_preview("", query: { "session" => preview.token })

        expect(response).to have_http_status(:bad_gateway)
        expect(response.headers["Location"]).to be_nil
        expect(response.body).to include("redirect target rejected")
      end
    end

    it "refuses a websocket upgrade instead of pretending it is tunneled" do
      allow(Workspaces::ManagerClient).to receive(:raw)

      visit_preview("live", query: { "session" => preview.token },
                    headers: { "Upgrade" => "websocket", "Connection" => "Upgrade" })

      expect(response).to have_http_status(:not_implemented)
      expect(response.body).to include("WebSocket")
      expect(Workspaces::ManagerClient).not_to have_received(:raw)
    end

    it "answers from the session cookie once the page asks for its own assets" do
      stub_upstream(response_body: %(<link href="/static/a.css">))
      visit_preview("", query: { "session" => preview.token })

      stub_upstream(response_body: "body{color:red}")
      visit_preview("static/a.css")

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("body{color:red}")
    end

    it "reports an unreachable preview server rather than an empty page" do
      allow(Workspaces::ManagerClient).to receive(:raw)
        .and_raise(Workspaces::Unavailable, "the manager is not reachable")

      visit_preview("", query: { "session" => preview.token })

      expect(response).to have_http_status(:bad_gateway)
      expect(response.body).to include("not reachable")
    end

    it "passes a refusal from the manager straight through" do
      allow(Workspaces::ManagerClient).to receive(:raw)
        .and_raise(Workspaces::Rejected.new(409, "no preview is running for this workspace"))

      visit_preview("", query: { "session" => preview.token })

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("no preview is running")
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
