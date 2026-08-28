# frozen_string_literal: true

class SendResult

  attr_accessor :type
  attr_accessor :details
  attr_accessor :retry
  attr_accessor :output
  attr_accessor :secure
  attr_accessor :connect_error
  attr_accessor :log_id
  attr_accessor :time
  attr_accessor :suppress_bounce
  attr_accessor :queue_retry_after
  attr_accessor :source_ip
  attr_accessor :remote_endpoint
  attr_accessor :attempted_endpoints
  attr_accessor :resolved_queue
  attr_accessor :rate_limited
  attr_accessor :backoff_matched

  def initialize
    @details = ""
    yield self if block_given?
  end

end
