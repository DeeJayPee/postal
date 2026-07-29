# frozen_string_literal: true

class AdminQueuesController < ApplicationController

  before_action :admin_required
  before_action :load_queue_configuration, only: [:edit_queue, :update_queue]
  before_action :load_mx_rollup, only: [:edit_rollup, :update_rollup]

  def index
    load_index_data
  end

  def create_queue
    @new_queue = QueueConfiguration.new(queue_create_params.merge(enabled: true))

    if @new_queue.save
      redirect_to admin_queues_path(anchor: "queue-configurations"), notice: "Queue #{@new_queue.queue_name} was added."
    else
      load_index_data
      render :index, status: :unprocessable_entity
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
      return render :edit_queue, status: :unprocessable_entity
    end

    previous_mode = @queue_configuration.mode
    QueueConfiguration.transaction do
      @queue_configuration.update!(attributes)

      if target_mode != previous_mode
        target_mode == "backoff" ? @queue_configuration.enter_backoff! : @queue_configuration.exit_backoff!
      end
    end

    redirect_to admin_queues_path(anchor: "queue-configurations"), notice: "Queue #{@queue_configuration.queue_name} was updated."
  rescue ActiveRecord::RecordInvalid
    @queue_configuration.mode = target_mode
    render :edit_queue, status: :unprocessable_entity
  end

  def create_rollup
    @new_rollup = MXRollup.new(rollup_params.merge(enabled: true))

    if rollup_queue_enabled?(@new_rollup) && @new_rollup.save
      redirect_to admin_queues_path(anchor: "mx-rollups"), notice: "MX rollup #{@new_rollup.mx_hostname} was added."
    else
      load_index_data
      render :index, status: :unprocessable_entity
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
      render :edit_rollup, status: :unprocessable_entity
    end
  end

  def smtp_probe
    probe_params = params.require(:smtp_probe).permit(:recipient, :queue_name, :mail_from)
    @smtp_probe_values = probe_params.to_h.symbolize_keys
    @smtp_probe_result = SMTPConnectionProbe.new(**@smtp_probe_values).call
    load_index_data
    render :index
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

    mode == "backoff" ? queue_config.enter_backoff! : queue_config.exit_backoff!
    redirect_to admin_queues_path, notice: "Queue #{queue_name} is now in #{mode} mode"
  end

  private

  def load_index_data
    @queue_configs = QueueConfiguration.enabled.order(:queue_name).to_a
    @rollups = MXRollup.enabled.order(:rollup_name, :mx_hostname).to_a
    @backoff_rules = BackoffRule.enabled.order(:action, :pattern).to_a

    known_queue_names = @queue_configs.map(&:queue_name)
    known_queue_names.concat(@rollups.map(&:rollup_name))
    known_queue_names.concat(DomainMacro.enabled.where.not(queue_name: [nil, ""]).distinct.pluck(:queue_name))
    known_queue_names.uniq!

    queue_summary = QueuedMessage.global_queue_summary(known_queue_names)
    @global_queue_size = queue_summary[:total]
    @known_queue_size = queue_summary[:known]
    @rest_queue_size = queue_summary[:rest]
    @queue_sizes = QueuedMessage.where(virtual_queue: @queue_configs.map(&:queue_name)).group(:virtual_queue).count

    @new_queue ||= QueueConfiguration.new
    @new_rollup ||= MXRollup.new
    @smtp_probe_values ||= {}
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
      :max_rcpt_per_message,
      :max_msg_rate,
      :mode,
      :backoff_reroute_to,
      :backoff_base_delay_seconds,
      :backoff_auto_success_threshold,
      :backoff_auto_success_window_seconds
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

end
