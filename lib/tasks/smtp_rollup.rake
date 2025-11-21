# frozen_string_literal: true

namespace :postal do
  namespace :smtp_rollup do

    desc "Import MX rollups from configuration file"
    task :import_mx_rollups, [:file_path] => :environment do |_t, args|
      file_path = args[:file_path] || Rails.root.join("config", "mx_rollups.conf")

      unless File.exist?(file_path)
        puts "Error: Configuration file not found at #{file_path}"
        exit 1
      end

      config_text = File.read(file_path)
      count = 0

      config_text.each_line do |line|
        next if line.strip.start_with?("#") || line.strip.empty?

        if line =~ /^\s*mx\s+(\S+)\s+(\S+)/
          mx_hostname = ::Regexp.last_match(1)
          rollup_name = ::Regexp.last_match(2)

          rollup = MxRollup.find_or_initialize_by(mx_hostname: mx_hostname)
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
      file_path = args[:file_path] || Rails.root.join("config", "domain_macros.conf")

      unless File.exist?(file_path)
        puts "Error: Configuration file not found at #{file_path}"
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
      file_path = args[:file_path] || Rails.root.join("config", "queue_configs.conf")

      unless File.exist?(file_path)
        puts "Error: Configuration file not found at #{file_path}"
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
          end
        end
      end

      puts "\nImported #{count} queue configuration(s)"
    end

    desc "Import all rollup configurations (MX rollups, domain macros, and queue configs)"
    task import_all: :environment do
      puts "=== Importing MX Rollups ==="
      Rake::Task["postal:smtp_rollup:import_mx_rollups"].invoke

      puts "\n=== Importing Domain Macros ==="
      Rake::Task["postal:smtp_rollup:import_domain_macros"].invoke

      puts "\n=== Importing Queue Configurations ==="
      Rake::Task["postal:smtp_rollup:import_queue_configs"].invoke

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

        MxRollup.enabled.order(:rollup_name, :mx_hostname).each do |rollup|
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
          f.puts "</domain>"
          f.puts ""
        end
      end

      puts "✓ Configurations exported to #{output_dir}"
    end

    desc "Show rollup statistics"
    task stats: :environment do
      puts "=== SMTP Rollup Statistics ==="
      puts ""
      puts "MX Rollups: #{MxRollup.enabled.count}"
      puts "Domain Macros: #{DomainMacro.enabled.count}"
      puts "Queue Configurations: #{QueueConfiguration.enabled.count}"
      puts ""

      puts "=== Rollup Groups ==="
      MxRollup.enabled.group(:rollup_name).count.each do |rollup_name, count|
        puts "  #{rollup_name}: #{count} MX record(s)"
      end
    end

  end
end
