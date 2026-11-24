module Workspaces
  # The manager said no. The status is the manager's own HTTP status, so the
  # panel can show the reason without guessing.
  class Rejected < StandardError
    attr_reader :status

    def initialize(status, message)
      super(message)
      @status = status
    end
  end
end
