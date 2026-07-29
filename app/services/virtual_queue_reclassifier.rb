# frozen_string_literal: true

# Re-evaluates queue assignments for pending messages which are currently in
# "Rest" or refer to a queue that is no longer enabled. Work is cursor-batched
# so an administrator can refresh large installations without one long request.
class VirtualQueueReclassifier

  BATCH_SIZE = 1_000

  Result = Struct.new(:scanned, :updated, :errors, :next_after_id, :more, keyword_init: true)

  def initialize(enabled_queue_names:, after_id: nil, dry_run: false, target_queue_name: nil,
                 batch_size: BATCH_SIZE, only_unassigned: true)
    @enabled_queue_names = enabled_queue_names
    @after_id = after_id.to_i
    @dry_run = dry_run
    @target_queue_name = target_queue_name.presence
    @batch_size = [[batch_size.to_i, 1].max, 10_000].min
    @only_unassigned = only_unassigned
    @resolved_domains = {}
  end

  def call
    relation = QueuedMessage.where(locked_at: nil).where("id > ?", @after_id).order(:id)
    relation = relation.merge(QueuedMessage.outside_virtual_queues(@enabled_queue_names)) if @only_unassigned
    messages = relation.limit(@batch_size).to_a
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
    queue_name = nil unless @enabled_queue_names.include?(queue_name)
    return false if @target_queue_name && queue_name != @target_queue_name

    desired_batch_key = "outgoing-#{queue_name || domain}"
    return false if queued_message.virtual_queue == queue_name && queued_message.batch_key == desired_batch_key

    return true if @dry_run

    queued_message.update_columns(
      virtual_queue: queue_name,
      batch_key: desired_batch_key,
      updated_at: Time.current
    )
    true
  end

end
