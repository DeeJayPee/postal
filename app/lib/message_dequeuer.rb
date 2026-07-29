# frozen_string_literal: true

module MessageDequeuer

  class << self

    def process(message, logger:, queue_lease: nil)
      processor = InitialProcessor.new(message, logger: logger, state: State.new(queue_lease: queue_lease))
      processor.process
    end

  end

end
