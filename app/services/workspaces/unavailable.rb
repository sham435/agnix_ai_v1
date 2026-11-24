module Workspaces
  # Raised whenever the execution capability cannot be reached or the daemon is
  # not answering. Callers must surface it as "unavailable" — never as a success
  # message invented locally.
  class Unavailable < StandardError; end
end
