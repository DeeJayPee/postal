# frozen_string_literal: true

# Re-evaluates queue assignments for pending messages which are currently in
# "Rest" or refer to a queue that is no longer enabled. Work is cursor-batched
# so an administrator can refresh large installations without one long request.
class VirtualQueueReclassifier

  BATCH_SIZE = 1_000

  Result = Struct.new(:scanned, :updated, :errors, :next_after_id, :more, keyword_init: true)

  def initialize(enabled_queue_names:, after_id: nil)
    @enabled_queue_names = enabled_queue_names
    @after_id = after_id.to_i
    @resolved_domains = {}
  end

  def call
    relation = QueuedMessage.outside_virtual_queues(@enabled_queue_names)
                            .where("id > ?", @after_id)
                            .order(:id)
    messages = relation.limit(BATCH_SIZE).to_a
    updated = 0
    errors = 0

    messages.each do |queued_message|
      updated += 1 if reclassify(queued_message)
    rescue StandardError => e
      errors += 1
      Postal.logger.error "Could not refresh virtual queue for queued message #{queued_message.id}: #{e.message}"
    end

    last_id = messages.last&.id || @after_id
    Result.new(
      scanned: messages.size,
      updated: updated,
      errors: errors,
      next_after_id: last_id,
      more: relation.where("id > ?", last_id).exists?
    )
  end

  private

  def reclassify(queued_message)
    message = queued_message.message
    return false unless message&.scope == "outgoing"

    domain = queued_message.domain.presence || message.recipient_domain
    return false if domain.blank?

    queue_name = @resolved_domains.fetch(domain) do
      @resolved_domains[domain] = SMTPRollupService.resolve_virtual_queue(domain)
    end
    return false unless @enabled_queue_names.include?(queue_name)

    queued_message.update_columns(
      virtual_queue: queue_name,
      batch_key: "outgoing-#{queue_name}",
      updated_at: Time.current
    )
    true
  end

end
