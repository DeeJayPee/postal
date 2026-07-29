# frozen_string_literal: true

class SMTPQueueScheduler
  Claim = Struct.new(:message, :lease, keyword_init: true)

  def initialize(ip_address_ids:, locker:, lock_time: Time.current)
    @ip_address_ids = ip_address_ids
    @locker = locker
    @lock_time = lock_time
  end

  def claim
    SMTPQueueLease.expire_stale!(@lock_time)

    candidate_states.each do |state|
      message = first_ready_message(state)
      next unless message

      lease = state.acquire_lease!(queued_message: message, locker: @locker, now: @lock_time)
      next unless lease

      locked = QueuedMessage.where(id: message.id, locked_by: nil, locked_at: nil)
                            .update_all(locked_by: @locker, locked_at: @lock_time)
      if locked == 1
        return Claim.new(message: QueuedMessage.find(message.id), lease: lease)
      end

      lease.release!
    end

    nil
  end

  private

  def candidate_states
    candidates = virtual_queue_candidates + domain_candidates + batch_candidates
    queue_keys = candidates.map { |message| SMTPQueueState.queue_key_for(message) }
    existing_states = SMTPQueueState.where(queue_key: queue_keys).index_by(&:queue_key)
    states = candidates.map do |message|
      queue_key = SMTPQueueState.queue_key_for(message)
      existing_states[queue_key] ||= SMTPQueueState.for_message!(message)
    end

    states.select { |state| state.eligible?(@lock_time) }
          .sort_by { |state| [state.last_dispatched_at || Time.at(0), state.queue_key] }
  end

  def virtual_queue_candidates
    ready_scope.where.not(virtual_queue: [nil, ""])
               .group(:virtual_queue)
               .minimum(:id)
               .values
               .then { |ids| QueuedMessage.where(id: ids).to_a }
  end

  def domain_candidates
    ready_scope.where(virtual_queue: [nil, ""])
               .where("batch_key LIKE ?", "outgoing-%")
               .where.not(domain: [nil, ""])
               .group(:domain)
               .minimum(:id)
               .values
               .then { |ids| QueuedMessage.where(id: ids).to_a }
  end

  def batch_candidates
    ready_scope.where(virtual_queue: [nil, ""])
               .where("batch_key IS NULL OR batch_key NOT LIKE ?", "outgoing-%")
               .group(:batch_key)
               .minimum(:id)
               .values
               .then { |ids| QueuedMessage.where(id: ids).to_a }
  end

  def ready_scope
    QueuedMessage.where(ip_address_id: [nil, @ip_address_ids])
                 .where(locked_by: nil, locked_at: nil)
                 .ready_with_delayed_retry
  end

  def first_ready_message(state)
    scope = ready_scope
    scope = if state.virtual_queue.present?
              scope.where(virtual_queue: state.virtual_queue)
            elsif state.batch_key.present?
              if state.batch_key.start_with?("__message__:")
                scope.where(id: state.batch_key.delete_prefix("__message__:").to_i)
              else
                scope.where(virtual_queue: [nil, ""]).where(batch_key: state.batch_key)
              end
            else
              scope.where(virtual_queue: [nil, ""])
                   .where(domain: state.domain)
                   .where("batch_key LIKE ?", "outgoing-%")
            end

    scope.order(:created_at, :id).first
  end
end
