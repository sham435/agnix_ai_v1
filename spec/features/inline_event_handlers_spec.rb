# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations

require "rails_helper"

# No inline event handler attributes in rendered markup.
#
# This app's CSP sets a nonce on script-src, and CSP3 says a nonce makes
# 'unsafe-inline' ineffective - not just for <script> tags but for event handler
# attributes as well. So `onchange="this.form.requestSubmit()"` (or onclick=,
# oninput=, ...) is parsed, kept in the DOM, and never executed: the control
# looks wired and does nothing. Development cannot show this because
# content_security_policy_report_only is on there, and a non-browser spec cannot
# show it either because it never runs JS - the agent page model switcher shipped
# broken exactly that way.
#
# Wiring belongs in Stimulus: data-controller + data-action (see
# app/javascript/controllers/auto_submit_controller.js for the select-saves-itself
# case).
RSpec.describe "Inline event handler ban" do
  def offending_lines
    events = %w[
      click dblclick mousedown mouseup mousemove mouseover mouseout mouseenter
      mouseleave change input submit focus blur keydown keyup keypress load error
      toggle select scroll contextmenu
    ]
    # `onchange="..."` as written in a template, and `onchange: "..."` as written
    # in a Ruby hash handed to a tag helper. The lookbehind keeps a word that only
    # ends in "on" plus an event name out of the match.
    html = /(?<![\w-])on(?:#{events.join("|")})\s*=\s*"/
    ruby = /(?<![\w-])on(?:#{events.join("|")})\s*:\s*["']/

    files = Dir[Rails.root.join("app/views/**/*.{erb,haml}")] +
      Dir[Rails.root.join("app/components/**/*.{erb,haml,rb}")]
    prefix = "#{Rails.root}/"

    files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        next unless line.match?(html) || line.match?(ruby)

        "#{file.delete_prefix(prefix)}:#{index + 1}: #{line.strip[0, 110]}"
      end
    end
  end

  it "finds no inline event handler attributes in views or components" do
    offenders = offending_lines

    expect(offenders).to be_empty,
      "inline event handlers never run under this app's CSP nonce; use data-controller/data-action instead:\n#{offenders.join("\n")}"
  end

  it "keeps the selects that save themselves wired through Stimulus" do
    # The ban only holds if the pattern it pushes is in real use, so pin the case
    # that motivated it: the agent page model switcher.
    switcher = File.read(Rails.root.join("app/views/agents/show.html.erb"))

    expect(switcher).to include(%q(controller: "auto-submit"))
    expect(switcher).to include(%q(action: "change->auto-submit#submit"))
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
