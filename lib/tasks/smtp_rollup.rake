# frozen_string_literal: true

require "pathname"

namespace :postal do
  namespace :smtp_rollup do

    def resolve_rollup_config_path(explicit_path, default_filename)
      candidates = []
      candidates << explicit_path.to_s if explicit_path
      candidates << File.join(rollup_config_dir, default_filename) if rollup_config_dir
      candidates << Rails.root.join("config", default_filename).to_s

      candidates.uniq!
      candidates.find { |p| p.present? && File.exist?(p) }
    end

    def rollup_config_dir
      base = Postal.config_file_path
      expanded = Pathname.new(base).absolute? ? base : Rails.root.join(base).to_s
      File.dirname(expanded)
    rescue StandardError
      nil
    end

    desc "Import MX rollups from configuration file"
    task :import_mx_rollups, [:file_path] => :environment do |_t, args|
      file_path = resolve_rollup_config_path(args[:file_path], "mx_rollups.conf")

      unless file_path
        searched = [
          args[:file_path],
          (File.join(rollup_config_dir, "mx_rollups.conf") if rollup_config_dir),
          Rails.root.join("config", "mx_rollups.conf")
        ].compact
        puts "Error: Configuration file not found. Looked in:\n#{searched.map { |p| "  - #{p}" }.join("\n") }"
        exit 1
      end

      config_text = File.read(file_path)
      count = 0

      config_text.each_line do |line|
        next if line.strip.start_with?("#") || line.strip.empty?

        if line =~ /^\s*mx\s+(\S+)\s+(\S+)/
          mx_hostname = ::Regexp.last_match(1)
          rollup_name = ::Regexp.last_match(2)

          rollup = MXRollup.find_or_initialize_by(mx_hostname: mx_hostname)
          rollup.rollup_name = rollup_name
          rollup.enabled = true

          if rollup.save
            puts "✓ Imported MX rollup: #{mx_hostname} -> #{rollup_name}"
            count += 1
          else
            puts "✗ Failed to import: #{mx_hostname} (#{rollup.errors.full_messages.join(', ')})"
          end
        end
      end

      puts "\nImported #{count} MX rollup(s)"
    end

    desc "Import domain macros from configuration file"
    task :import_domain_macros, [:file_path] => :environment do |_t, args|
      file_path = resolve_rollup_config_path(args[:file_path], "domain_macros.conf")

      unless file_path
        searched = [
          args[:file_path],
          (File.join(rollup_config_dir, "domain_macros.conf") if rollup_config_dir),
          Rails.root.join("config", "domain_macros.conf")
        ].compact
        puts "Error: Configuration file not found. Looked in:\n#{searched.map { |p| "  - #{p}" }.join("\n") }"
        exit 1
      end

      config_text = File.read(file_path)
      count = 0
      current_macro = nil

      config_text.each_line do |line|
        next if line.strip.start_with?("#") || line.strip.empty?

        if line =~ /^\s*domain-macro\s+(\S+)\s+(.+)/
          name = ::Regexp.last_match(1)
          domains_str = ::Regexp.last_match(2)

          current_macro = DomainMacro.find_or_initialize_by(name: name)
          current_macro.domains = domains_str
          current_macro.enabled = true

          if current_macro.save
            puts "✓ Imported domain macro: #{name}"
            count += 1
          else
            puts "✗ Failed to import: #{name} (#{current_macro.errors.full_messages.join(', ')})"
          end
        elsif line =~ /^\s*queue-to\s+(\S+)/ && current_macro
          queue_name = ::Regexp.last_match(1)
          current_macro.queue_name = queue_name
          current_macro.save
          puts "  → Queue: #{queue_name}"
        end
      end

      puts "\nImported #{count} domain macro(s)"
    end

    desc "Import queue configurations from configuration file"
    task :import_queue_configs, [:file_path] => :environment do |_t, args|
      file_path = resolve_rollup_config_path(args[:file_path], "queue_configs.conf")

      unless file_path
        searched = [
          args[:file_path],
          (File.join(rollup_config_dir, "queue_configs.conf") if rollup_config_dir),
          Rails.root.join("config", "queue_configs.conf")
        ].compact
        puts "Error: Configuration file not found. Looked in:\n#{searched.map { |p| "  - #{p}" }.join("\n") }"
        exit 1
      end

      config_text = File.read(file_path)
      count = 0
      current_queue = nil

      config_text.each_line do |line|
        next if line.strip.start_with?("#") || line.strip.empty?

        if line =~ /^\s*<domain\s+(\S+)>/
          queue_name = ::Regexp.last_match(1)
          current_queue = QueueConfiguration.find_or_initialize_by(queue_name: queue_name)
          current_queue.enabled = true
        elsif line =~ /^\s*<\/domain>/
          if current_queue&.save
            puts "✓ Imported queue config: #{current_queue.queue_name}"
            puts "  → min_smtp_out: #{current_queue.min_smtp_out}"
            puts "  → max_smtp_out: #{current_queue.max_smtp_out}"
            puts "  → max_rcpt_per_message: #{current_queue.max_rcpt_per_message}"
            puts "  → max_msg_rate: #{current_queue.max_msg_rate}" if current_queue.max_msg_rate.present?
            puts "  → backoff_reroute_to: #{current_queue.backoff_reroute_to}" if current_queue.backoff_reroute_to.present?
            puts "  → mode: #{current_queue.mode}" if current_queue.mode.present?
            puts "  → backoff_base_delay_seconds: #{current_queue.backoff_base_delay_seconds}" if current_queue.backoff_base_delay_seconds.present?
            count += 1
          elsif current_queue
            puts "✗ Failed to import: #{current_queue.queue_name} (#{current_queue.errors.full_messages.join(', ')})"
          end
          current_queue = nil
        elsif current_queue
          if line =~ /^\s*min-smtp-out\s+(\d+)/
            current_queue.min_smtp_out = ::Regexp.last_match(1).to_i
          elsif line =~ /^\s*max-smtp-out\s+(\d+)/
            current_queue.max_smtp_out = ::Regexp.last_match(1).to_i
          elsif line =~ /^\s*max-rcpt-per-message\s+(\d+)/
            current_queue.max_rcpt_per_message = ::Regexp.last_match(1).to_i
          elsif line =~ /^\s*max-msg-rate\s+(\d+\/[dhms])/
            current_queue.max_msg_rate = ::Regexp.last_match(1)
          elsif line =~ /^\s*backoff-reroute-to\s+(\S+)/
            current_queue.backoff_reroute_to = ::Regexp.last_match(1)
          elsif line =~ /^\s*mode\s+(normal|backoff)/
            current_queue.mode = ::Regexp.last_match(1)
          elsif line =~ /^\s*backoff-base-delay\s+(\d+)([dhms])/
            current_queue.backoff_base_delay_seconds = QueueConfiguration.duration_to_seconds(::Regexp.last_match(1).to_i, ::Regexp.last_match(2))
          elsif line =~ /^\s*backoff-auto-success-threshold\s+(\d+)/
            current_queue.backoff_auto_success_threshold = ::Regexp.last_match(1).to_i
          elsif line =~ /^\s*backoff-auto-success-window\s+(\d+)([dhms])/
            current_queue.backoff_auto_success_window_seconds = QueueConfiguration.duration_to_seconds(::Regexp.last_match(1).to_i, ::Regexp.last_match(2))
          end
        end
      end

      puts "\nImported #{count} queue configuration(s)"
    end

    desc "Import global SMTP backoff rules from configuration file"
    task :import_backoff_rules, [:file_path] => :environment do |_t, args|
      file_path = resolve_rollup_config_path(args[:file_path], "backoff_rules.conf")

      unless file_path
        searched = [
          args[:file_path],
          (File.join(rollup_config_dir, "backoff_rules.conf") if rollup_config_dir),
          Rails.root.join("config", "backoff_rules.conf")
        ].compact
        puts "Error: Configuration file not found. Looked in:\n#{searched.map { |p| "  - #{p}" }.join("\n") }"
        exit 1
      end

      config_text = File.read(file_path)
      BackoffRule.import_from_config(config_text)
      puts "✓ Imported backoff rules from #{file_path}"
      puts "  → enabled rules: #{BackoffRule.enabled.count}"
    end

    desc "Import all rollup configurations (MX rollups, domain macros, queue configs, and backoff rules)"
    task import_all: :environment do
      puts "=== Importing MX Rollups ==="
      Rake::Task["postal:smtp_rollup:import_mx_rollups"].invoke

      puts "\n=== Importing Domain Macros ==="
      Rake::Task["postal:smtp_rollup:import_domain_macros"].invoke

      puts "\n=== Importing Queue Configurations ==="
      Rake::Task["postal:smtp_rollup:import_queue_configs"].invoke

      puts "\n=== Importing Backoff Rules ==="
      Rake::Task["postal:smtp_rollup:import_backoff_rules"].invoke

      puts "\n✓ All configurations imported successfully!"
    end

    desc "Export current rollup configurations"
    task export: :environment do
      output_dir = Rails.root.join("config", "rollup_export")
      FileUtils.mkdir_p(output_dir)

      # Export MX rollups
      File.open(output_dir.join("mx_rollups.conf"), "w") do |f|
        f.puts "# MX Rollup Configuration"
        f.puts "# Format: mx <mx_hostname> <rollup_name>"
        f.puts ""

        MXRollup.enabled.order(:rollup_name, :mx_hostname).each do |rollup|
          f.puts "mx #{rollup.mx_hostname} #{rollup.rollup_name}"
        end
      end

      # Export domain macros
      File.open(output_dir.join("domain_macros.conf"), "w") do |f|
        f.puts "# Domain Macro Configuration"
        f.puts "# Format: domain-macro <name> <domain1>,<domain2>,..."
        f.puts ""

        DomainMacro.enabled.order(:name).each do |macro|
          f.puts "domain-macro #{macro.name} #{macro.domains}"
          f.puts "    queue-to #{macro.queue_name}" if macro.queue_name.present?
        end
      end

      # Export queue configurations
      File.open(output_dir.join("queue_configs.conf"), "w") do |f|
        f.puts "# Queue Configuration"
        f.puts "# Format: <domain queue_name> ... </domain>"
        f.puts ""

        QueueConfiguration.enabled.order(:queue_name).each do |config|
          f.puts "<domain #{config.queue_name}>"
          f.puts "    min-smtp-out #{config.min_smtp_out}"
          f.puts "    max-smtp-out #{config.max_smtp_out}"
          f.puts "    max-rcpt-per-message #{config.max_rcpt_per_message}"
          f.puts "    max-msg-rate #{config.max_msg_rate}" if config.max_msg_rate.present?
          f.puts "    backoff-reroute-to #{config.backoff_reroute_to}" if config.backoff_reroute_to.present?
          f.puts "    mode #{config.mode}" if config.mode.present?
          if config.backoff_base_delay_seconds.present?
            hours = (config.backoff_base_delay_seconds.to_i / 3600.0)
            f.puts "    backoff-base-delay #{hours.ceil}h"
          end
          f.puts "    backoff-auto-success-threshold #{config.backoff_auto_success_threshold}" if config.backoff_auto_success_threshold.present?
          if config.backoff_auto_success_window_seconds.present?
            hours = (config.backoff_auto_success_window_seconds.to_i / 3600.0)
            f.puts "    backoff-auto-success-window #{hours.ceil}h"
          end
          f.puts "</domain>"
          f.puts ""
        end
      end

      File.open(output_dir.join("backoff_rules.conf"), "w") do |f|
        f.puts "# Global SMTP Backoff Rules"
        f.puts "<smtp-pattern-list blocking-errors>"
        BackoffRule.enabled.order(:id).each do |rule|
          f.puts "    reply /#{rule.pattern}/ #{rule.action}"
        end
        f.puts "</smtp-pattern-list>"
      end

      puts "✓ Configurations exported to #{output_dir}"
    end

    desc "Show rollup statistics"
    task stats: :environment do
      puts "=== SMTP Rollup Statistics ==="
      puts ""
      puts "MX Rollups: #{MXRollup.enabled.count}"
      puts "Domain Macros: #{DomainMacro.enabled.count}"
      puts "Queue Configurations: #{QueueConfiguration.enabled.count}"
      puts "Backoff Rules: #{BackoffRule.enabled.count}"
      puts ""

      puts "=== Rollup Groups ==="
      MXRollup.enabled.group(:rollup_name).count.each do |rollup_name, count|
        puts "  #{rollup_name}: #{count} MX record(s)"
      end
    end

    desc "Add/update a queue. Usage: rake 'postal:smtp_rollup:add_queue[name,min,max,max_rcpt,max_msg_rate]'"
    task :add_queue, [:queue_name, :min_smtp_out, :max_smtp_out, :max_rcpt_per_message, :max_msg_rate] => :environment do |_t, args|
      queue = QueueConfiguration.find_or_initialize_by(queue_name: args[:queue_name].to_s.strip)
      queue.enabled = true
      queue.min_smtp_out = args[:min_smtp_out] if args[:min_smtp_out].present?
      queue.max_smtp_out = args[:max_smtp_out] if args[:max_smtp_out].present?
      queue.max_rcpt_per_message = args[:max_rcpt_per_message] if args[:max_rcpt_per_message].present?
      queue.max_msg_rate = args[:max_msg_rate] if args[:max_msg_rate].present?

      if queue.save
        puts "✓ Queue #{queue.queue_name} saved"
      else
        puts "✗ #{queue.errors.full_messages.join(', ')}"
        exit 1
      end
    end

    desc "Add/update an MX rollup. Usage: rake 'postal:smtp_rollup:add_mx_rollup[mx.example.net,queue.name]'"
    task :add_mx_rollup, [:mx_hostname, :rollup_name] => :environment do |_t, args|
      hostname = args[:mx_hostname].to_s.strip.downcase.delete_suffix(".")
      rollup = MXRollup.where("LOWER(mx_hostname) = ?", hostname).first_or_initialize
      rollup.rollup_name = args[:rollup_name].to_s.strip
      rollup.enabled = true

      if rollup.save
        puts "✓ MX rollup #{rollup.mx_hostname} -> #{rollup.rollup_name} saved"
      else
        puts "✗ #{rollup.errors.full_messages.join(', ')}"
        exit 1
      end
    end

    desc "Probe SMTP without DATA. Usage: rake 'postal:smtp_rollup:probe_smtp[user@example.net,queue.name,from@example.org]'"
    task :probe_smtp, [:recipient, :queue_name, :mail_from] => :environment do |_t, args|
      probe = SMTPConnectionProbe.new(
        recipient: args[:recipient],
        queue_name: args[:queue_name],
        mail_from: args[:mail_from]
      ).call

      puts probe.summary
      puts probe.transcript
      exit 1 unless probe.connected
    end

    desc "Set queue mode (normal|backoff). Usage: rake postal:smtp_rollup:set_queue_mode[queue,mode]"
    task :set_queue_mode, [:queue_name, :mode] => :environment do |_t, args|
      queue_name = args[:queue_name].to_s
      mode = args[:mode].to_s

      if queue_name.blank? || !QueueConfiguration::MODES.include?(mode)
        puts "Usage: bundle exec rake postal:smtp_rollup:set_queue_mode[queue_name,normal|backoff]"
        exit 1
      end

      queue = QueueConfiguration.find_for_queue(queue_name)
      unless queue
        puts "Queue not found or disabled: #{queue_name}"
        exit 1
      end

      mode == "backoff" ? queue.enter_backoff! : queue.exit_backoff!
      puts "✓ Queue #{queue_name} set to #{queue.mode} mode"
    end

    desc "Show queue mode. Usage: rake postal:smtp_rollup:queue_mode[queue]"
    task :queue_mode, [:queue_name] => :environment do |_t, args|
      queue_name = args[:queue_name].to_s
      if queue_name.blank?
        puts "Usage: bundle exec rake postal:smtp_rollup:queue_mode[queue_name]"
        exit 1
      end

      queue = QueueConfiguration.find_for_queue(queue_name)
      unless queue
        puts "Queue not found or disabled: #{queue_name}"
        exit 1
      end

      puts "Queue: #{queue.queue_name}"
      puts "Mode: #{queue.mode}"
      puts "Backoff base delay: #{queue.effective_backoff_base_delay}s"
      puts "Backoff started at: #{queue.backoff_started_at || '-'}"
      puts "Backoff success count: #{queue.backoff_success_count}"
    end

  end
end
