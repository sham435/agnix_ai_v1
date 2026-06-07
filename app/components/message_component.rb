class MessageComponent < ViewComponent::Base
  def initialize(message:, streaming: false)
    @message = message
    @streaming = streaming
  end

  private

  attr_reader :message, :streaming
end
