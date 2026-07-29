# frozen_string_literal: true

module MessageDequeuer
  class State

    attr_accessor :send_result

    def initialize(queue_lease: nil)
      @queue_lease = queue_lease
      @queue_blocked = false
    end

    def renew_queue_lease!
      @queue_lease&.renew!
    end

    def record_send_result(result)
      outcome = @queue_lease&.smtp_queue_state&.record_result!(result)
      @queue_blocked = true if outcome == :deferred
    end

    def queue_blocked?
      @queue_blocked
    end

    def sender_for(klass, *args, **kwargs)
      @cached_senders ||= {}
      cache_kwargs = kwargs.except(:mx_attempt_offset)
      @cached_senders[[klass, args, cache_kwargs]] ||= begin
        klass_instance = klass.new(*args, **kwargs)
        klass_instance.start
        klass_instance
      end
    end

    def finished
      @cached_senders&.each_value do |sender|
        sender.finish
      rescue StandardError
        false
      end
    end

  end
end
