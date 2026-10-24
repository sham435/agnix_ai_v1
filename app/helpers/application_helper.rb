module ApplicationHelper
  include Pagy::Frontend

  # Render markdown content with syntax highlighting.
  #
  # Uses Commonmarker (GFM: tables, task lists, strikethrough, autolink) with
  # built-in Rouge highlighting, then decorates fenced code blocks with a
  # header bar (language badge + copy button) so long code feels native.
  def render_markdown(text)
    return "" if text.blank?

    begin
      html = if defined?(Commonmarker)
        Commonmarker.to_html(
          text,
          options: { options: [ :UNSAFE, :FOOTNOTES, :SMART ], extensions: [ :TABLE, :STRIKETHROUGH, :TASKLIST, :AUTOLINK ] }
        )
      else
        simple_format(text)
      end

      decorate_code_blocks(html).html_safe
    rescue => e
      Rails.logger.error "Markdown render error: #{e.message}"
      simple_format(text)
    end
  end

  # Wrap <pre lang="..."><code> blocks in a card with a language badge and a
  # copy button; strip Commonmarker's inline bg style so we own the theme.
  def decorate_code_blocks(html)
    doc = Nokogiri::HTML5.fragment(html)

    doc.css("pre").each do |pre|
      lang = pre["lang"].presence || "text"
      pre.remove_attribute("style")

      copy = %(
        <button type="button" class="code-copy" data-action="click->chat#copyCode" title="Copy code">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="9" y="9" width="13" height="13" rx="2"/>
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
          </svg>
        </button>
      )

      lang_badge = content_tag(:span, lang, class: "code-lang", data: { raw: lang })

      card = %(<div class="code-block">)
      card << %(<div class="code-header">#{lang_badge}#{copy}</div>)
      card << %(<pre class="code-pre" lang="#{ERB::Util.html_escape(lang)}">#{pre.inner_html}</pre>)
      card << %(</div>)

      pre.replace(card)
    end

    doc.to_html
  end

  # Format a timestamp.
  def time_ago(time)
    return "" unless time
    time_ago_in_words(time) + " ago"
  end

  # Truncate text with HTML support.
  def truncate_html(text, length: 100)
    ActionController::Base.helpers.truncate(text, length: length, separator: " ")
  end

  # Badge component for status display.
  def status_badge(status)
    classes = case status.to_s
    when "active", "completed", "paid", "running"
      "badge badge-active"
    else
      "badge badge-inactive"
    end

    content_tag(:span, status.to_s.titleize, class: classes)
  end

  # Agent model display name.
  def model_display_name(agent)
    "#{agent.provider.titleize} • #{agent.model}"
  end

  # ── Phase 1 app shell ──────────────────────────────────────────────────
  # Server-resolved theme for the no-FOUC head script. Returns "dark"/"light"
  # when the user has an explicit preference, else nil (the inline script then
  # falls back to localStorage -> prefers-color-scheme -> dark).
  def initial_theme
    current_user&.resolved_ui_theme
  end

  # True when the current request is "at" this sidebar destination. Root is an
  # exact match (so /conversations/:id doesn't also light up "Chats"); every
  # other item matches on a path prefix.
  def sidebar_nav_active?(path)
    request.path == path
  end

  # Bucket an already-loaded list of conversations into ChatGPT-style recency
  # groups. Presentation only — never queries the database.
  def group_conversations_by_recency(list)
    now = Time.zone.now
    today = now.beginning_of_day
    yesterday = (now - 1.day).beginning_of_day
    week = (now - 7.days).beginning_of_day
    month = (now - 30.days).beginning_of_day

    buckets = { "Today" => [], "Yesterday" => [], "Previous 7 Days" => [], "Previous 30 Days" => [], "Older" => [] }
    list.each do |c|
      t = c.updated_at || c.created_at
      buckets["Today"]            << c if t >= today
      buckets["Yesterday"]        << c if t >= yesterday && t < today
      buckets["Previous 7 Days"]  << c if t >= week && t < yesterday
      buckets["Previous 30 Days"] << c if t >= month && t < week
      buckets["Older"]            << c if t < month
    end
    buckets.reject { |_k, v| v.empty? }.to_a
  end
end
