# frozen_string_literal: true

module Worker
  module Jobs
    class ProcessQueuedMessagesJob < BaseJob

      def call
        @lock_time = Time.current
        @locker = Postal.locker_name_with_suffix(SecureRandom.hex(8))

        find_ip_addresses
        lock_message_for_processing
        process_messages
        @messages_to_process
      end

      private

      # Returns an array of IP address IDs that are present on the host that is
      # running this job.
      #
      # @return [Array<Integer>]
      def find_ip_addresses
        ip_addresses = { 4 => [], 6 => [] }
        Socket.ip_address_list.each do |address|
          next if local_ip?(address.ip_address)

          ip_addresses[address.ipv4? ? 4 : 6] << address.ip_address
        end
        @ip_addresses = IPAddress.where(ipv4: ip_addresses[4]).or(IPAddress.where(ipv6: ip_addresses[6])).pluck(:id)
      end

      # Is the given IP address a local address?
      #
      # @param [String] ip
      # @return [Boolean]
      def local_ip?(ip)
        !!(ip =~ /\A(127\.|fe80:|::)/)
      end

      # Obtain a queued message from the database for processing
      #
      # @return [void]
      def lock_message_for_processing
        @claim = SMTPQueueScheduler.new(
          ip_address_ids: @ip_addresses,
          locker: @locker,
          lock_time: @lock_time
        ).claim
        @messages_to_process = @claim ? [@claim.message] : []
      end

      # Process the messages we obtained from the database
      #
      # @return [void]
      def process_messages
        @messages_to_process.each do |message|
          work_completed!
          begin
            MessageDequeuer.process(message, logger: logger, queue_lease: @claim.lease)
          ensure
            @claim.lease.release!
          end
        end
      end

    end
  end
end
