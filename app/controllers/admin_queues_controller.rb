# frozen_string_literal: true

class AdminQueuesController < ApplicationController

  ACTIVITY_RANGES = {
    "15m" => 15.minutes,
    "1h" => 1.hour,
    "6h" => 6.hours,
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days
  }.freeze
  INDEX_TABS = %w[overview configurations rollups rules diagnostics].freeze

  before_action :admin_required
  before_action :load_queue_configuration, only: [:show_queue, :queue_activity, :edit_queue, :update_queue]
  before_action :load_mx_rollup, only: [:edit_rollup, :update_rollup]

  def index
    load_index_data
  end

  def show_queue
    load_queue_detail_data
  end

  def runtime
    load_runtime_data
    render json: global_runtime_payload
  end

  def queue_activity
    range_key = selected_activity_range
    render json: {
      queue: @queue_configuration.queue_name,
      range: range_key,
      snapshot_at: Time.current.iso8601,
      series: activity_series([@queue_configuration.queue_name], ACTIVITY_RANGES.fetch(range_key))
    }
  end

  def create_queue
    @new_queue = QueueConfiguration.new(queue_create_params.merge(enabled: true))

    if @new_queue.save
      redirect_to admin_queues_path(anchor: "queue-configurations"), notice: "Queue #{@new_queue.queue_name} was added."
    else
      load_index_data
      render :index, status: :unprocessable_content
    end
  end

  def edit_queue
  end

  def update_queue
    attributes = queue_update_params.to_h.symbolize_keys
    target_mode = attributes.delete(:mode).presence || @queue_configuration.mode

    unless QueueConfiguration::MODES.include?(target_mode)
      @queue_configuration.assign_attributes(attributes)
      @queue_configuration.errors.add(:mode, "is invalid")
      return render :edit_queue, status: :unprocessable_content
    end

    previous_mode = @queue_configuration.mode
    QueueConfiguration.transaction do
      @queue_configuration.update!(attributes)

      if target_mode != previous_mode
        if target_mode == "backoff"
          @queue_configuration.enter_backoff!(source: "manual", actor_id: current_user.id, details: "Mode changed from queue editor")
        else
          @queue_configuration.exit_backoff!(source: "manual", actor_id: current_user.id, details: "Mode changed from queue editor")
        end
      end
    end

    redirect_to admin_queues_path(anchor: "queue-configurations"), notice: "Queue #{@queue_configuration.queue_name} was updated."
  rescue ActiveRecord::RecordInvalid
    @queue_configuration.mode = target_mode
    render :edit_queue, status: :unprocessable_content
  end

  def create_rollup
    @new_rollup = MXRollup.new(rollup_params.merge(enabled: true))

    if rollup_queue_enabled?(@new_rollup) && @new_rollup.save
      redirect_to admin_queues_path(anchor: "mx-rollups"), notice: "MX rollup #{@new_rollup.mx_hostname} was added."
    else
      load_index_data
      render :index, status: :unprocessable_content
    end
  end

  def edit_rollup
    load_queue_choices
  end

  def update_rollup
    @mx_rollup.assign_attributes(rollup_params)

    if rollup_queue_enabled?(@mx_rollup) && @mx_rollup.save
      redirect_to admin_queues_path(anchor: "mx-rollups"), notice: "MX rollup #{@mx_rollup.mx_hostname} was updated."
    else
      load_queue_choices
      render :edit_rollup, status: :unprocessable_content
    end
  end

  def smtp_probe
    probe_params = params.require(:smtp_probe).permit(:recipient, :queue_name, :mail_from)
    @smtp_probe_values = probe_params.to_h.symbolize_keys
    @smtp_probe_result = SMTPConnectionProbe.new(**@smtp_probe_values).call

    queue_config = QueueConfiguration.find_for_queue(@smtp_probe_values[:queue_name])
    record_probe_event(queue_config, @smtp_probe_result) if queue_config
    if @smtp_probe_result.recipient_accepted && queue_config&.backoff?
      diagnostic_result = probe_send_result(@smtp_probe_result)
      queue_config.exit_backoff!(
        source: "smtp_probe",
        actor_id: current_user.id,
        result: diagnostic_result,
        details: "Successful SMTP diagnostic returned the queue to normal mode"
      )
      @smtp_probe_recovered_queue = queue_config.queue_name
    end

    if queue_config && params[:queue_id].to_i == queue_config.id
      @queue_configuration = queue_config
      load_queue_detail_data
      render :show_queue
    else
      load_index_data
      render :index
    end
  end

  def retry_queue
    queue_config = QueueConfiguration.find_for_queue(params[:queue_name].to_s)
    unless queue_config
      return redirect_to admin_queues_path, alert: "Queue not found or not enabled"
    end

    scheduled_messages = QueuedMessage.where(virtual_queue: queue_config.queue_name, locked_at: nil)
                                      .where("retry_after IS NOT NULL AND retry_after >= ?", 30.seconds.ago)
    scheduled_count = scheduled_messages.count
    scheduled_messages.update_all(retry_after: nil)
    SMTPQueueState.for_virtual_queue!(queue_config.queue_name).retry_now!
    SMTPQueueEvent.record_transition!(
      queue_configuration: queue_config,
      event_type: "retry_requested",
      category: "manual",
      source: "manual",
      actor_id: current_user.id,
      details: "#{scheduled_count} delayed message(s) made eligible for delivery"
    )

    redirect_to_with_return_to admin_queues_path(tab: "overview"),
                               notice: "#{scheduled_count} message(s) in #{queue_config.queue_name} are eligible for the next worker run."
  end

  def retry_rest
    unlocked_messages = rest_queue_scope.where(locked_at: nil)

    scheduled_messages = unlocked_messages.where("retry_after IS NOT NULL AND retry_after >= ?", 30.seconds.ago)
    scheduled_count = scheduled_messages.update_all(retry_after: nil, updated_at: Time.current)
    state_count = 0
    unlocked_messages.select(:id, :virtual_queue, :domain, :batch_key).find_in_batches(batch_size: 1_000) do |messages|
      queue_keys = messages.map { |message| SMTPQueueState.queue_key_for(message) }.uniq
      blocked_states = SMTPQueueState.where(queue_key: queue_keys)
                                     .where("next_attempt_at IS NOT NULL OR consecutive_failures <> 0 OR last_error IS NOT NULL")
      state_count += blocked_states.update_all(
        next_attempt_at: nil,
        consecutive_failures: 0,
        last_error: nil,
        updated_at: Time.current
      )
    end

    redirect_to_with_return_to admin_queues_path(anchor: "rest-queue"),
                               notice: "#{scheduled_count} delayed Rest message(s) and #{state_count} scheduler state(s) are eligible for the next worker run."
  end

  def debug_rest
    scope = rest_queue_scope
    @rest_runtime = QueuedMessage.runtime_summary(scope)
    @rest_unassigned_count = scope.where(virtual_queue: [nil, ""]).count
    @rest_unknown_queues = scope.where.not(virtual_queue: [nil, ""])
                                .group(:virtual_queue)
                                .order(Arel.sql("COUNT(*) DESC"))
                                .count

    domain_totals = scope.group(:domain).order(Arel.sql("COUNT(*) DESC")).limit(100).count
    domains = domain_totals.keys
    domain_scope = scope.where(domain: domains)
    domain_locked = domain_scope.where.not(locked_at: nil).group(:domain).count
    domain_ready = domain_scope.where(locked_at: nil).ready_with_delayed_retry.group(:domain).count
    domain_scheduled_scope = domain_scope.where(locked_at: nil)
                                         .where("retry_after IS NOT NULL AND retry_after >= ?", 30.seconds.ago)
    domain_scheduled = domain_scheduled_scope.group(:domain).count
    domain_next_attempt = domain_scheduled_scope.group(:domain).minimum(:retry_after)
    @rest_domains = domain_totals.map do |domain, total|
      {
        domain: domain,
        total: total,
        ready: domain_ready[domain].to_i,
        scheduled: domain_scheduled[domain].to_i,
        locked: domain_locked[domain].to_i,
        next_attempt_at: domain_next_attempt[domain]
      }
    end

    @rest_messages = scope.includes(server: :organization).order(:created_at, :id).page(params[:page]).per(100)
    queue_keys = @rest_messages.map { |message| SMTPQueueState.queue_key_for(message) }
    states = SMTPQueueState.where(queue_key: queue_keys).index_by(&:queue_key)
    @rest_message_diagnostics = @rest_messages.index_with do |message|
      queue_key = SMTPQueueState.queue_key_for(message)
      {
        queue_key: queue_key,
        reason: rest_reason(message),
        state: states[queue_key]
      }
    end

    debug_domain = params[:domain].to_s.strip.downcase.delete_suffix(".")
    @rest_domain_debug = debug_rest_domain(debug_domain) if debug_domain.present? && scope.where(domain: debug_domain).exists?
  end

  def refresh_queue_assignments
    enabled_queue_names = QueueConfiguration.enabled.pluck(:queue_name)
    refresh_result = VirtualQueueReclassifier.new(
      enabled_queue_names: enabled_queue_names,
      after_id: params[:after_id]
    ).call

    redirect_params = { anchor: "queue-configurations" }
    redirect_params[:reclassify_after] = refresh_result.next_after_id if refresh_result.more
    notice = "Scanned #{refresh_result.scanned} pending message(s); assigned #{refresh_result.updated} to enabled queues."
    notice += " #{refresh_result.errors} error(s) were logged." if refresh_result.errors.positive?
    notice += " Click refresh assignments again to process the next batch." if refresh_result.more

    redirect_to admin_queues_path(**redirect_params), notice: notice
  end

  def set_mode
    queue_name = params[:queue_name].to_s
    mode = params[:mode].to_s

    unless QueueConfiguration::MODES.include?(mode)
      return redirect_to admin_queues_path, alert: "Invalid queue mode"
    end

    queue_config = QueueConfiguration.find_for_queue(queue_name)
    unless queue_config
      return redirect_to admin_queues_path, alert: "Queue not found or not enabled"
    end

    if mode == "backoff"
      queue_config.enter_backoff!(source: "manual", actor_id: current_user.id, details: "Mode changed from queue cockpit")
    else
      queue_config.exit_backoff!(source: "manual", actor_id: current_user.id, details: "Mode changed from queue cockpit")
    end
    redirect_to_with_return_to admin_queues_path(tab: "overview"), notice: "Queue #{queue_name} is now in #{mode} mode"
  end

  private

  def load_index_data
    @active_tab = INDEX_TABS.include?(params[:tab]) ? params[:tab] : "overview"
    load_runtime_data
    @rollups = MXRollup.enabled.order(:rollup_name, :mx_hostname).to_a
    @backoff_rules = BackoffRule.enabled.order(:action, :pattern).to_a
    load_overview_observability if @active_tab == "overview"

    @reclassify_after = params[:reclassify_after].to_i
    @new_queue ||= QueueConfiguration.new
    @new_rollup ||= MXRollup.new
    @smtp_probe_values ||= {}
    @smtp_probe_values[:queue_name] ||= params[:queue_name] if params[:queue_name].present?
    @smtp_probe_values[:mail_from] ||= default_probe_mail_from
  end

  def load_runtime_data
    @queue_configs = QueueConfiguration.enabled.order(:queue_name).to_a
    snapshot = QueuedMessage.observability_snapshot(known_queue_names)
    @global_queue_size = snapshot[:total]
    @known_queue_size = snapshot[:known]
    @rest_queue_size = snapshot[:rest_count]
    @global_runtime = snapshot[:global]
    @rest_runtime = snapshot[:rest]
    @queue_runtime = snapshot[:queues].slice(*@queue_configs.map(&:queue_name))

    queue_states = SMTPQueueState.where(
      queue_key: @queue_configs.map { |config| "virtual:#{config.queue_name}" }
    ).includes(:smtp_queue_leases).index_by(&:virtual_queue)
    queue_configs_by_name = @queue_configs.index_by(&:queue_name)
    @queue_runtime.each do |queue_name, runtime|
      state = queue_states[queue_name]
      config = queue_configs_by_name.fetch(queue_name)
      runtime[:active_smtp_out] = state&.active_lease_count.to_i
      runtime[:smtp_out_limit] = state&.consecutive_failures.to_i.positive? ? 1 : config.effective_max_smtp_out
      runtime[:queue_next_attempt_at] = state&.next_attempt_at
      runtime[:last_error] = state&.last_error
      runtime[:consecutive_failures] = state&.consecutive_failures.to_i
    end
    @queue_rows = @queue_configs.map do |config|
      runtime = @queue_runtime.fetch(config.queue_name)
      {
        config: config,
        runtime: runtime,
        status: queue_status(config, runtime),
        latest_event: nil,
        activity: { sent: 0, soft_fail: 0, hard_fail: 0 }
      }
    end
    filter_and_sort_queue_rows!
    @backoff_queue_count = @queue_configs.count(&:backoff?)
    @queue_snapshot_at = Time.current
  end

  def load_overview_observability
    queue_names = @queue_configs.map(&:queue_name)
    latest_event_ids = SMTPQueueEvent.where(queue_name: queue_names).group(:queue_name).maximum(:id).values
    @latest_queue_events = SMTPQueueEvent.where(id: latest_event_ids).index_by(&:queue_name)
    one_hour_ago = 1.hour.ago
    activity_queue_names = queue_names + [SMTPQueueActivityBucket::REST_QUEUE_NAME]
    activity = SMTPQueueActivityBucket.where(queue_name: activity_queue_names).where("bucket_started_at >= ?", one_hour_ago)
    activity_by_queue = activity.group(:queue_name).pluck(
      :queue_name,
      Arel.sql("SUM(sent_count)"),
      Arel.sql("SUM(soft_fail_count)"),
      Arel.sql("SUM(hard_fail_count)")
    ).to_h do |queue_name, sent, soft_fail, hard_fail|
      [queue_name, { sent: sent.to_i, soft_fail: soft_fail.to_i, hard_fail: hard_fail.to_i }]
    end
    @queue_rows.each do |row|
      queue_name = row[:config].queue_name
      row[:latest_event] = @latest_queue_events[queue_name]
      row[:activity] = activity_by_queue.fetch(queue_name, { sent: 0, soft_fail: 0, hard_fail: 0 })
    end
    @rest_activity = activity_by_queue.fetch(SMTPQueueActivityBucket::REST_QUEUE_NAME, { sent: 0, soft_fail: 0, hard_fail: 0 })
    @top_queue_domains = QueuedMessage.domain_observability.to_h { |domain| [domain[:domain], domain[:total]] }
    @global_activity_range = "24h"
    @global_activity_series = activity_series(activity_queue_names, ACTIVITY_RANGES.fetch(@global_activity_range))
  end

  def load_queue_detail_data
    queue_name = @queue_configuration.queue_name
    scope = QueuedMessage.where(virtual_queue: queue_name)
    @queue_runtime_detail = QueuedMessage.runtime_summary(scope)
    @queue_state = SMTPQueueState.find_by(queue_key: "virtual:#{queue_name}")
    @queue_runtime_detail[:active_smtp_out] = @queue_state&.active_lease_count.to_i
    @queue_runtime_detail[:smtp_out_limit] = @queue_state&.consecutive_failures.to_i.positive? ? 1 : @queue_configuration.effective_max_smtp_out
    @queue_runtime_detail[:queue_next_attempt_at] = @queue_state&.next_attempt_at
    @queue_runtime_detail[:last_error] = @queue_state&.last_error
    @queue_next_attempt = [@queue_runtime_detail[:next_attempt_at], @queue_state&.next_attempt_at].compact.max

    backoff_trigger_scope = SMTPQueueEvent.where(queue_name: queue_name, event_type: "backoff_entered")
    if @queue_configuration.backoff_started_at
      backoff_trigger_scope = backoff_trigger_scope.where(
        "first_occurred_at >= ?",
        @queue_configuration.backoff_started_at - 1.second
      )
    end
    @backoff_trigger = backoff_trigger_scope.recent_first.first
    @backoff_trigger_last_seen = backoff_trigger_last_seen(queue_name, @backoff_trigger)
    @latest_queue_event = SMTPQueueEvent.where(queue_name: queue_name).recent_first.first
    @activity_range = selected_activity_range
    @activity_series = activity_series([queue_name], ACTIVITY_RANGES.fetch(@activity_range))
    @activity_totals = activity_totals([queue_name], ACTIVITY_RANGES.fetch(@activity_range))

    base_event_scope = SMTPQueueEvent.where(queue_name: queue_name)
    @event_categories = base_event_scope.where.not(category: [nil, ""]).distinct.order(:category).pluck(:category)
    event_scope = base_event_scope.recent_first
    event_scope = event_scope.where(event_type: params[:event_type]) if SMTPQueueEvent::EVENT_TYPES.include?(params[:event_type])
    event_scope = event_scope.where(category: params[:category]) if params[:category].present?
    event_scope = event_scope.where(domain: params[:domain].to_s.downcase) if params[:domain].present?
    if params[:event_query].present?
      query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:event_query].to_s.strip)}%"
      event_scope = event_scope.where("smtp_response LIKE :query OR details LIKE :query OR log_id LIKE :query", query: query)
    end
    @queue_events = event_scope.includes(:actor, :backoff_rule).page(params[:event_page]).per(50)

    @queue_domains = QueuedMessage.domain_observability(scope)

    @queue_messages = scope.includes(:ip_address, server: :organization)
                           .order(:created_at, :id)
                           .page(params[:message_page])
                           .per(50)
    @smtp_probe_values ||= { queue_name: queue_name, mail_from: default_probe_mail_from }
    @queue_snapshot_at = Time.current
  end

  def filter_and_sort_queue_rows!
    query = params[:queue_query].to_s.strip.downcase
    @queue_rows.select! do |row|
      query.blank? || row[:config].queue_name.downcase.include?(query) || row[:config].description.to_s.downcase.include?(query)
    end

    case params[:queue_status]
    when "attention"
      @queue_rows.select! { |row| %w[backoff deferred].include?(row[:status]) }
    when "backoff", "deferred", "normal"
      @queue_rows.select! { |row| row[:status] == params[:queue_status] }
    when "rest"
      @queue_rows = []
    end

    @queue_rows.sort_by! do |row|
      runtime = row[:runtime]
      case params[:queue_sort]
      when "volume"
        [-runtime[:total].to_i, row[:config].queue_name]
      when "oldest"
        [runtime[:oldest_at] || Time.utc(3000), row[:config].queue_name]
      when "name"
        [row[:config].queue_name]
      else
        priority = { "backoff" => 0, "deferred" => 1, "normal" => 2 }.fetch(row[:status], 3)
        [priority, runtime[:oldest_at] || Time.utc(3000), -runtime[:total].to_i, row[:config].queue_name]
      end
    end
  end

  def queue_status(config, runtime)
    return "backoff" if config.backoff?
    return "deferred" if runtime[:consecutive_failures].positive? || runtime[:queue_next_attempt_at]&.future?

    "normal"
  end

  def selected_activity_range
    ACTIVITY_RANGES.key?(params[:range]) ? params[:range] : "1h"
  end

  def activity_series(queue_names, duration)
    start_time = duration.ago
    resolution = [[(duration.to_i / 300.0).ceil, 60].max.fdiv(60).ceil * 60, 60].max
    buckets = {}
    SMTPQueueActivityBucket.where(queue_name: queue_names)
                           .where("bucket_started_at >= ?", start_time)
                           .pluck(:bucket_started_at, :sent_count, :soft_fail_count, :hard_fail_count,
                                  :connect_error_count, :rate_limited_count, :backoff_matched_count)
                           .each do |values|
      time, sent, soft_fail, hard_fail, connect_error, rate_limited, backoff_matched = values
      bucket_time = Time.at((time.to_i / resolution) * resolution).utc
      bucket = buckets[bucket_time] ||= {
        time: bucket_time.iso8601,
        sent: 0,
        soft_fail: 0,
        hard_fail: 0,
        connect_error: 0,
        rate_limited: 0,
        backoff_matched: 0
      }
      bucket[:sent] += sent.to_i
      bucket[:soft_fail] += soft_fail.to_i
      bucket[:hard_fail] += hard_fail.to_i
      bucket[:connect_error] += connect_error.to_i
      bucket[:rate_limited] += rate_limited.to_i
      bucket[:backoff_matched] += backoff_matched.to_i
    end
    buckets.values.sort_by { |bucket| bucket[:time] }
  end

  def activity_totals(queue_names, duration)
    relation = SMTPQueueActivityBucket.where(queue_name: queue_names).where("bucket_started_at >= ?", duration.ago)
    values = relation.pick(
      Arel.sql("COALESCE(SUM(attempted_count), 0)"),
      Arel.sql("COALESCE(SUM(sent_count), 0)"),
      Arel.sql("COALESCE(SUM(soft_fail_count), 0)"),
      Arel.sql("COALESCE(SUM(hard_fail_count), 0)"),
      Arel.sql("COALESCE(SUM(connect_error_count), 0)"),
      Arel.sql("COALESCE(SUM(rate_limited_count), 0)"),
      Arel.sql("COALESCE(SUM(backoff_matched_count), 0)")
    )
    {
      attempted: values[0].to_i,
      sent: values[1].to_i,
      soft_fail: values[2].to_i,
      hard_fail: values[3].to_i,
      connect_error: values[4].to_i,
      rate_limited: values[5].to_i,
      backoff_matched: values[6].to_i
    }
  end

  def global_runtime_payload
    {
      snapshot_at: @queue_snapshot_at.iso8601,
      stats: {
        total: @global_queue_size,
        ready: @global_runtime[:ready],
        scheduled: @global_runtime[:scheduled],
        locked: @global_runtime[:locked],
        backoff: @backoff_queue_count,
        rest: @rest_queue_size
      },
      rest: {
        total: @rest_runtime[:total],
        ready: @rest_runtime[:ready],
        scheduled: @rest_runtime[:scheduled],
        locked: @rest_runtime[:locked],
        next_attempt_at: @rest_runtime[:next_attempt_at]&.iso8601,
        oldest_at: @rest_runtime[:oldest_at]&.iso8601
      },
      queues: @queue_rows.map do |row|
        runtime = row[:runtime]
        {
          name: row[:config].queue_name,
          status: row[:status],
          total: runtime[:total],
          ready: runtime[:ready],
          scheduled: runtime[:scheduled],
          locked: runtime[:locked],
          active_smtp_out: runtime[:active_smtp_out],
          smtp_out_limit: runtime[:smtp_out_limit],
          next_attempt_at: [runtime[:next_attempt_at], runtime[:queue_next_attempt_at]].compact.max&.iso8601,
          oldest_at: runtime[:oldest_at]&.iso8601
        }
      end
    }
  end

  def record_probe_event(queue_config, probe_result)
    event_type = probe_result.recipient_accepted ? "diagnostic_succeeded" : "diagnostic_failed"
    SMTPQueueEvent.record_transition!(
      queue_configuration: queue_config,
      event_type: event_type,
      category: probe_result.connected ? "smtp" : "connection",
      source: "smtp_probe",
      severity: probe_result.recipient_accepted ? "info" : "warning",
      actor_id: current_user.id,
      result: probe_send_result(probe_result),
      domain: probe_result.recipient_domain,
      details: probe_result.summary
    )
  end

  def backoff_trigger_last_seen(queue_name, trigger)
    return unless trigger

    issues = SMTPQueueEvent.where(queue_name: queue_name, event_type: "delivery_issue")
                           .where("last_occurred_at >= ?", trigger.first_occurred_at)
    if trigger.backoff_rule_id
      issues = issues.where(backoff_rule_id: trigger.backoff_rule_id)
    elsif trigger.smtp_response.present?
      issues = issues.where(smtp_response: trigger.smtp_response)
    else
      return trigger.last_occurred_at
    end
    [trigger.last_occurred_at, issues.maximum(:last_occurred_at)].compact.max
  end

  def probe_send_result(probe_result)
    SendResult.new do |result|
      result.type = probe_result.recipient_accepted ? "Sent" : "SoftFail"
      result.details = probe_result.summary
      result.remote_endpoint = probe_result.endpoint
      result.resolved_queue = probe_result.resolved_queue
      result.connect_error = !probe_result.connected
    end
  end

  def load_queue_configuration
    @queue_configuration = QueueConfiguration.enabled.find(params[:id])
  end

  def load_mx_rollup
    @mx_rollup = MXRollup.enabled.find(params[:id])
  end

  def load_queue_choices
    @queue_configs = QueueConfiguration.enabled.order(:queue_name).to_a
  end

  def queue_create_params
    params.require(:queue_configuration).permit(
      :queue_name,
      *queue_setting_keys
    )
  end

  def queue_update_params
    params.require(:queue_configuration).permit(*queue_setting_keys)
  end

  def queue_setting_keys
    [
      :description,
      :min_smtp_out,
      :max_smtp_out,
      :backoff_max_smtp_out,
      :max_rcpt_per_message,
      :max_msg_rate,
      :retry_after,
      :backoff_retry_after,
      :max_msg_per_connection,
      :mx_connection_attempts,
      :mode,
      :backoff_reroute_to,
      :backoff_base_delay_seconds,
      :backoff_auto_success_threshold,
      :backoff_auto_success_window_seconds,
    ]
  end

  def rollup_params
    params.require(:mx_rollup).permit(:mx_hostname, :rollup_name, :description)
  end

  def rollup_queue_enabled?(rollup)
    rollup.rollup_name = rollup.rollup_name.to_s.strip
    return true if QueueConfiguration.find_for_queue(rollup.rollup_name)

    rollup.errors.add(:rollup_name, "must reference an enabled queue")
    false
  end

  def known_queue_names
    @known_queue_names ||= begin
      names = @queue_configs ? @queue_configs.map(&:queue_name) : QueueConfiguration.enabled.pluck(:queue_name)
      names.concat(MXRollup.enabled.distinct.pluck(:rollup_name))
      names.concat(DomainMacro.enabled.where.not(queue_name: [nil, ""]).distinct.pluck(:queue_name))
      names.uniq
    end
  end

  def rest_queue_scope
    QueuedMessage.outside_virtual_queues(known_queue_names)
  end

  def rest_reason(message)
    if message.virtual_queue.blank?
      "No virtual queue assigned; the scheduler uses the recipient domain or batch key."
    else
      "Stored virtual queue #{message.virtual_queue.inspect} is not present in any enabled queue, MX rollup, or domain macro."
    end
  end

  def debug_rest_domain(domain)
    macro_queue = DomainMacro.find_queue_for_domain(domain)
    mx_records = DNSResolver.local.mx(domain, raise_timeout_errors: false)
    mx_matches = mx_records.map do |priority, hostname|
      {
        priority: priority,
        hostname: hostname,
        queue_name: MXRollup.find_rollup_for_mx(hostname)
      }
    end
    resolved_queue = macro_queue.presence || mx_matches.filter_map { |record| record[:queue_name] }.first

    {
      domain: domain,
      macro_queue: macro_queue,
      mx_matches: mx_matches,
      resolved_queue: resolved_queue,
      queue_enabled: resolved_queue.present? && QueueConfiguration.find_for_queue(resolved_queue).present?
    }
  rescue StandardError => e
    {
      domain: domain,
      error: "#{e.class}: #{e.message}"
    }
  end

  def default_probe_mail_from
    domain = Postal::Config.dns.return_path_domain.presence || Postal::Config.postal.smtp_hostname
    domain.present? ? "postmaster@#{domain}" : nil
  end

end
