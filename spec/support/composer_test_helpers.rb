# frozen_string_literal: true

# Shared helpers for system specs that need to exercise the composer's
# platform-specific submit policy (§6 of the UI requirements).
#
# The composer's `ChatInputController.platformOf()` reads the browser's real
# platform, so system specs running on a macOS dev laptop see "mac" behaviour
# (bare Enter inserts a newline) while CI on Linux sees "desktop" (bare Enter
# submits). To keep specs deterministic and readable we stub the classifier
# inside the headless page before typing, so every test can pin the policy it
# is asserting against.
module ComposerTestHelpers
  # Force the composer to behave as the given platform for the rest of the
  # example. Must be called AFTER `visit` so the chat-input Stimulus
  # controller has connected.
  def stub_composer_platform(platform)
    page.execute_script(<<~JS)
      (() => {
        const ctrl = window.Stimulus.controllers.find((c) => c.identifier === 'chat-input')
        if (!ctrl) throw new Error('chat-input controller not connected')
        const klass = ctrl.constructor
        if (!klass._origPlatformOf) klass._origPlatformOf = klass.platformOf.bind(klass)
        klass.platformOf = () => '#{platform}'
        klass._platformCache = null
      })()
    JS
  end

  # Convenience: pin the platform to "desktop" so `send_keys(:enter)` triggers
  # a submit like the pre-§6 composer did.
  def stub_composer_desktop!
    stub_composer_platform("desktop")
  end

  # Fill the composer and submit it using the desktop Enter policy,
  # regardless of the OS running the suite.
  def desktop_submit(text)
    stub_composer_desktop!
    fill_in "message-input", with: text
    find("#message-input").send_keys(:enter)
  end
end

RSpec.configure do |config|
  config.include ComposerTestHelpers, type: :system
end
