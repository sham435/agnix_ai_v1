require "uri"

class WorkspacePreviewsController < ApplicationController
  # The authenticated door into a sandbox's HTTP server.
  #
  # A workspace container publishes no port and has no inbound route, so this
  # action is the only way preview traffic can reach it. Before a single byte is
  # forwarded, four things must be true: the workspace belongs to the signed-in
  # user, the preview session is live, the port in the URL is the one that
  # session opened, and the request is ordinary HTTP. Nothing here lets a caller
  # name a destination — the target is always this workspace's own preview
  # container, and the manager refuses any port it did not open itself.
  #
  # CSRF protection is skipped for this action rather than verified: the
  # unguessable session token is what authorises the request, the body is handed
  # to the sandbox's own server and never touches this app's state, and a form
  # inside a preview has no token of ours to carry.
  skip_before_action :verify_authenticity_token, only: :proxy
  before_action :isolate_preview, only: :proxy
  before_action :authenticate_user!, only: :proxy

  PREVIEW_POLICY = "sandbox allow-scripts allow-forms; default-src 'none'; " \
                   "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " \
                   "img-src 'self' data:; font-src 'self'; connect-src 'none'; " \
                   "form-action 'self'; base-uri 'none'; frame-ancestors 'self'".freeze

  MAX_REQUEST_BYTES = 5 * 1024 * 1024

  # What the sandbox server may learn about the visitor: nothing. These three
  # only make ordinary pages and form posts work.
  REQUEST_HEADERS = %w[Content-Type Accept User-Agent].freeze

  # Headers worth passing back to the browser. Anything framing, cookie-bearing
  # or hop-by-hop is dropped and rebuilt here.
  RESPONSE_HEADERS = %w[retry-after].freeze

  NO_BODY_STATUSES = [ 204, 205, 304 ].freeze

  # Absolute in-app URLs have to be re-pointed at the preview prefix, or the page
  # would ask this app for /static/style.css and get its own 404.
  ABSOLUTE_ATTR = %r{((?:href|src|action|poster|data-src)\s*=\s*)(["'])/([^"']*)(\2)}i
  CSS_URL = %r{(url\()(['"]?)/([^)'"]*)(\2\))}i

  def proxy
    workspace = Workspace.where(user: current_user).find_by(id: params[:id])
    return render_plain(:not_found, "no such workspace for this account") if workspace.nil?

    preview = live_preview_session(workspace)
    return render_plain(:forbidden, "this preview link is not valid for this workspace") if preview.nil?
    return render_plain(:forbidden, "this preview session opened port #{preview.port}, not #{params[:port]}") if preview.port != params[:port].to_i

    # The manager forwards HTTP only; a socket it held open would outlive the
    # request/response loop this gateway is built on. Say so instead of failing
    # the page silently.
    return render_plain(:not_implemented, websocket_refusal) if websocket_upgrade?

    body = request_body
    return render_plain(:payload_too_large, "preview request bodies are capped at #{MAX_REQUEST_BYTES} bytes") if body == :too_large

    result = Workspaces::Provider.forward_preview(
      preview,
      method: request.request_method,
      sub_path: params[:path].to_s,
      query: request.query_parameters.except("session"),
      headers: forwarded_request_headers,
      body: body
    )
    remember_preview_session(preview, workspace)
    serve(result, workspace, preview)
  rescue Workspaces::Unavailable => e
    render_plain(:bad_gateway, "the preview server is not reachable: #{e.message}")
  rescue Workspaces::Rejected => e
    render_plain(e.status.between?(400, 599) ? e.status : 502, e.message)
  end

  private

  def isolate_preview
    response.set_header("Content-Security-Policy", PREVIEW_POLICY)
    response.set_header("Cache-Control", "private, no-store")
    response.set_header("Referrer-Policy", "no-referrer")
    response.set_header("X-Content-Type-Options", "nosniff")
  end

  # The token arrives either in the link we issued or, for the sub-resources that
  # link pulls in (css, js, images), in a cookie scoped to this preview's own
  # path — so no asset request has to know the token, and none of them survives
  # the session's expiry.
  def live_preview_session(workspace)
    token = request.query_parameters["session"].presence || cookies[preview_cookie_name(workspace)].presence
    return nil if token.blank?

    preview = WorkspacePreviewSession.find_by(token: token, workspace: workspace)
    return nil if preview.nil?
    return nil unless preview.active?

    preview
  end

  # The issued link carries the token; the page it returns does not, so the
  # cookie lets the css/js/image requests under this preview's path through.
  def remember_preview_session(preview, workspace)
    return if request.query_parameters["session"].blank?

    cookies[preview_cookie_name(workspace)] = {
      value: preview.token,
      path: preview_prefix(preview.workspace, preview.port),
      expires: preview.expires_at,
      httponly: true,
      same_site: :lax,
      secure: request.ssl?
    }
  end

  def request_body
    return nil unless %w[POST PUT PATCH DELETE].include?(request.request_method)
    return :too_large if request.content_length.to_i > MAX_REQUEST_BYTES

    request.body.rewind if request.body.respond_to?(:rewind)
    raw = request.body.read(MAX_REQUEST_BYTES + 1).to_s
    return :too_large if raw.bytesize > MAX_REQUEST_BYTES

    raw
  end

  def websocket_upgrade?
    request.headers["HTTP_UPGRADE"].to_s.downcase.include?("websocket")
  end

  def websocket_refusal
    <<~TEXT
      This preview gateway forwards HTTP requests only; a WebSocket upgrade was
      refused, so live-reload in the sandboxed app will not connect. The page
      itself works, and a reload fetches the current build through this route.
    TEXT
  end

  def forwarded_request_headers
    REQUEST_HEADERS.filter_map do |name|
      value = request.headers[name]
      [ name, value ] if value.present?
    end.to_h
  end

  def serve(result, workspace, preview)
    status = result[:status].to_i
    headers = result[:headers] || {}
    content_type = headers["content-type"]&.first.to_s
    body = result[:body].to_s

    RESPONSE_HEADERS.each do |name|
      value = headers[name]&.first
      response.set_header(name, value) if value.present?
    end

    if (300..399).cover?(status)
      location = headers["location"]&.first.to_s
      if location.present?
        return render_plain(:bad_gateway, "preview redirect target rejected") unless safe_preview_redirect?(location)

        response.set_header("Location", location.start_with?("/") ? rebase(location, workspace, preview.port) : location)
      end
      head(status)
      return
    end

    body = rewrite_links(body, workspace, preview.port) if text_body?(content_type)
    self.response.status = status
    response.set_header("Content-Type", content_type.presence || "text/html; charset=utf-8")
    # Same-origin on purpose: the preview is this app's own route, and a page
    # served here must never be embeddable somewhere else.
    response.set_header("X-Frame-Options", "SAMEORIGIN")
    self.response_body = NO_BODY_STATUSES.include?(status) ? "" : body
  end

  def text_body?(content_type)
    %w[html css javascript json xml text].any? { |kind| content_type.include?(kind) }
  end

  def safe_preview_redirect?(location)
    return false if location.match?(/[\x00-\x1f\x7f\\]/)

    uri = URI.parse(location)
    uri.scheme.nil? && uri.host.nil? && !location.start_with?("//")
  rescue URI::InvalidURIError
    false
  end

  def preview_prefix(workspace, port)
    "/workspaces/#{workspace.id}/preview/#{port}"
  end

  def preview_cookie_name(workspace)
    "shams_ws_preview_#{workspace.id}"
  end

  # /static/app.css -> /workspaces/<id>/preview/<port>/static/app.css
  def rebase(path, workspace, port)
    preview_prefix(workspace, port) + path
  end

  def rewrite_links(body, workspace, port)
    body.gsub(ABSOLUTE_ATTR) do
      attribute, quote, target, closing = Regexp.last_match.captures
      "#{attribute}#{quote}#{rebase("/#{target}", workspace, port)}#{closing}"
    end.gsub(CSS_URL) do
      open, quote, target, closing = Regexp.last_match.captures
      "#{open}#{quote}#{rebase("/#{target}", workspace, port)}#{closing}"
    end
  end

  def render_plain(status, message)
    render status: status, plain: message
  end
end
