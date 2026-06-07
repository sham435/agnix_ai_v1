module ApplicationHelper
  include Pagy::Frontend

  # Render markdown content with syntax highlighting.
  def render_markdown(text)
    return "" if text.blank?

    begin
      CommonMarker.render_html(text, options: [:UNSAFE, :FOOTNOTES])
        .html_safe
    rescue => e
      Rails.logger.error "Markdown render error: #{e.message}"
      simple_format(text)
    end
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
end
