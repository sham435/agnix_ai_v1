ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up development by caching.

# The precompiled `pg` gem bundles a libpq linked against Apple's
# Kerberos.framework. Its default gssencmode=prefer makes every fresh
# connection enumerate Kerberos credential caches, and that plugin crashes
# (SIGSEGV in os_log_preferences_refresh) from Solid Queue's forked/threaded
# workers. This app never uses GSS encryption, so default it off on macOS
# only - before any connection is opened. Override with PGGSSENCMODE if a
# deployment ever needs GSS.
ENV["PGGSSENCMODE"] ||= "disable" if RUBY_PLATFORM.include?("darwin")
