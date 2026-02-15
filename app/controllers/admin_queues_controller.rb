# frozen_string_literal: true

class AdminQueuesController < ApplicationController

  before_action :admin_required

  def index
    @queue_configs = QueueConfiguration.enabled.order(:queue_name)
    @backoff_rules = BackoffRule.enabled.order(:action, :pattern)
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

end
