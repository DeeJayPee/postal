# frozen_string_literal: true

# SMTP Rollup Initializer
# This ensures the rollup service and related classes are loaded

Rails.application.config.to_prepare do
  # Preload rollup-related classes
  require_dependency "smtp_rollup_service" if defined?(SmtpRollupService)
  require_dependency "smtp_sender_with_rollup" if defined?(SMTPSenderWithRollup)

  # Log rollup configuration on startup
  if defined?(Rails::Console) || ENV["POSTAL_SMTP_ROLLUP_VERBOSE"]
    Rails.logger.info "SMTP Rollup System Initialized"
    Rails.logger.info "  MX Rollups: #{MxRollup.enabled.count}" if defined?(MxRollup)
    Rails.logger.info "  Domain Macros: #{DomainMacro.enabled.count}" if defined?(DomainMacro)
    Rails.logger.info "  Queue Configs: #{QueueConfiguration.enabled.count}" if defined?(QueueConfiguration)
  end
rescue StandardError => e
  Rails.logger.warn "SMTP Rollup initialization skipped: #{e.message}"
end
