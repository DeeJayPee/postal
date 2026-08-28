# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminQueuesController, type: :controller do

  let(:admin) { instance_double(User, admin?: true, time_zone: "UTC") }

  before do
    allow(controller).to receive(:logged_in?).and_return(true)
    allow(controller).to receive(:current_user).and_return(admin)
  end

  describe "PATCH update_queue" do
    let!(:queue) do
      QueueConfiguration.create!(
        queue_name: "example.queue",
        min_smtp_out: 1,
        max_smtp_out: 2,
        max_rcpt_per_message: 100,
        mode: "normal"
      )
    end

    it "updates queue settings but ignores queue name changes" do
      patch :update_queue, params: {
        id: queue.id,
        queue_configuration: {
          queue_name: "renamed.queue",
          backoff_reroute_to: "relay.example.net",
          max_msg_rate: "2000/h",
          min_smtp_out: 2,
          max_smtp_out: 5,
          backoff_max_smtp_out: 2,
          max_rcpt_per_message: 50,
          retry_after: "15m",
          backoff_retry_after: "2h",
          max_msg_per_connection: 25,
          mx_connection_attempts: 3,
          backoff_base_delay_seconds: 10_800,
          backoff_auto_success_threshold: 3,
          backoff_auto_success_window_seconds: 21_600,
          description: "Updated from the admin UI"
        }
      }

      expect(response).to redirect_to(admin_queues_path(anchor: "queue-configurations"))
      expect(queue.reload).to have_attributes(
        queue_name: "example.queue",
        backoff_reroute_to: "relay.example.net",
        max_msg_rate: "2000/h",
        min_smtp_out: 2,
        max_smtp_out: 5,
        backoff_max_smtp_out: 2,
        max_rcpt_per_message: 50,
        retry_after: "15m",
        backoff_retry_after: "2h",
        max_msg_per_connection: 25,
        mx_connection_attempts: 3,
        backoff_base_delay_seconds: 10_800,
        backoff_auto_success_threshold: 3,
        backoff_auto_success_window_seconds: 21_600,
        description: "Updated from the admin UI"
      )
    end

    it "uses the queue transition method when entering backoff" do
      patch :update_queue, params: {
        id: queue.id,
        queue_configuration: { mode: "backoff" }
      }

      expect(response).to redirect_to(admin_queues_path(anchor: "queue-configurations"))
      expect(queue.reload).to be_backoff
      expect(queue.backoff_started_at).to be_present
      expect(queue.backoff_success_count).to eq(0)
    end

    it "uses the queue transition method when returning to normal" do
      queue.enter_backoff!
      queue.update!(backoff_success_count: 2, backoff_last_success_at: Time.current)

      patch :update_queue, params: {
        id: queue.id,
        queue_configuration: { mode: "normal" }
      }

      expect(response).to redirect_to(admin_queues_path(anchor: "queue-configurations"))
      expect(queue.reload).to be_normal
      expect(queue.backoff_started_at).to be_nil
      expect(queue.backoff_last_success_at).to be_nil
      expect(queue.backoff_success_count).to eq(0)
    end

    it "renders validation failures without persisting partial changes" do
      patch :update_queue, params: {
        id: queue.id,
        queue_configuration: {
          backoff_reroute_to: "relay.example.net",
          max_msg_rate: "invalid"
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(queue.reload.backoff_reroute_to).to be_nil
      expect(queue.max_msg_rate).to be_nil
    end
  end

  describe "PATCH update_rollup" do
    let!(:queue) { QueueConfiguration.create!(queue_name: "example.queue") }
    let!(:other_queue) { QueueConfiguration.create!(queue_name: "other.queue") }
    let!(:rollup) { MXRollup.create!(mx_hostname: "mx.example.net", rollup_name: queue.queue_name) }

    it "updates and normalizes the MX mapping" do
      patch :update_rollup, params: {
        id: rollup.id,
        mx_rollup: {
          mx_hostname: "MX2.Example.NET.",
          rollup_name: other_queue.queue_name,
          description: "Updated mapping"
        }
      }

      expect(response).to redirect_to(admin_queues_path(anchor: "mx-rollups"))
      expect(rollup.reload).to have_attributes(
        mx_hostname: "mx2.example.net",
        rollup_name: "other.queue",
        description: "Updated mapping"
      )
    end

    it "rejects a mapping to a queue that is not enabled" do
      other_queue.update!(enabled: false)

      patch :update_rollup, params: {
        id: rollup.id,
        mx_rollup: {
          mx_hostname: "mx2.example.net",
          rollup_name: other_queue.queue_name
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(rollup.reload).to have_attributes(
        mx_hostname: "mx.example.net",
        rollup_name: "example.queue"
      )
    end
  end

  describe "POST retry_queue" do
    it "makes scheduled unlocked messages eligible without changing locked messages" do
      queue = QueueConfiguration.create!(queue_name: "example.queue")
      scheduled = create(:queued_message, virtual_queue: queue.queue_name, retry_after: 1.hour.from_now)
      locked = create(:queued_message, :locked, virtual_queue: queue.queue_name, retry_after: 1.hour.from_now)
      state = SMTPQueueState.for_virtual_queue!(queue.queue_name)
      state.update!(next_attempt_at: 1.hour.from_now, consecutive_failures: 1)

      post :retry_queue, params: { queue_name: queue.queue_name }

      expect(response).to redirect_to(admin_queues_path(anchor: "queue-configurations"))
      expect(scheduled.reload.retry_after).to be_nil
      expect(locked.reload.retry_after).to be_present
      expect(state.reload.next_attempt_at).to be_nil
    end
  end

  describe "POST retry_rest" do
    it "makes delayed Rest messages and their scheduler state eligible" do
      QueueConfiguration.create!(queue_name: "known.queue")
      scheduled = create(
        :queued_message,
        virtual_queue: nil,
        domain: "rest.example",
        batch_key: "outgoing-rest.example",
        retry_after: 1.hour.from_now
      )
      known = create(:queued_message, virtual_queue: "known.queue", retry_after: 1.hour.from_now)
      locked = create(
        :queued_message,
        :locked,
        virtual_queue: nil,
        domain: "locked.example",
        batch_key: "outgoing-locked.example",
        retry_after: 1.hour.from_now
      )
      state = SMTPQueueState.for_message!(scheduled)
      state.update!(next_attempt_at: 1.hour.from_now, consecutive_failures: 1)

      post :retry_rest

      expect(response).to redirect_to(admin_queues_path(anchor: "rest-queue"))
      expect(scheduled.reload.retry_after).to be_nil
      expect(known.reload.retry_after).to be_present
      expect(locked.reload.retry_after).to be_present
      expect(state.reload).to have_attributes(next_attempt_at: nil, consecutive_failures: 0)
    end
  end

  describe "GET debug_rest" do
    it "shows only messages outside known virtual queues" do
      QueueConfiguration.create!(queue_name: "known.queue")
      rest = create(:queued_message, virtual_queue: nil, domain: "rest.example")
      create(:queued_message, virtual_queue: "known.queue", domain: "known.example")

      get :debug_rest

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@rest_messages)).to contain_exactly(rest)
      expect(controller.instance_variable_get(:@rest_domains).first).to include(domain: "rest.example", total: 1)
    end

    it "resolves one selected Rest domain without changing its assignment" do
      queue = QueueConfiguration.create!(queue_name: "resolved.queue")
      MXRollup.create!(mx_hostname: "mx.rest.example", rollup_name: queue.queue_name)
      rest = create(:queued_message, virtual_queue: nil, domain: "rest.example")
      resolver = instance_double(DNSResolver, mx: [[10, "mx.rest.example"]])
      allow(DNSResolver).to receive(:local).and_return(resolver)

      get :debug_rest, params: { domain: rest.domain }

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@rest_domain_debug)).to include(
        domain: "rest.example",
        resolved_queue: "resolved.queue",
        queue_enabled: true
      )
      expect(rest.reload.virtual_queue).to be_nil
    end
  end

  describe "POST smtp_probe" do
    it "returns a backoff queue to normal after a successful real delivery" do
      queue = QueueConfiguration.create!(queue_name: "example.queue", mode: "backoff")
      result = SMTPConnectionProbe::Result.new(
        connected: true,
        recipient_accepted: true,
        summary: "accepted",
        transcript: "250 OK"
      )
      probe = instance_double(SMTPConnectionProbe, call: result)
      allow(SMTPConnectionProbe).to receive(:new).and_return(probe)

      post :smtp_probe, params: {
        smtp_probe: {
          queue_name: queue.queue_name,
          recipient: "user@example.net",
          mail_from: "sender@example.org"
        }
      }

      expect(response).to have_http_status(:ok)
      expect(queue.reload).to be_normal
    end
  end

  describe "POST refresh_queue_assignments" do
    it "runs one cursor batch and preserves the next cursor" do
      QueueConfiguration.create!(queue_name: "example.queue")
      result = VirtualQueueReclassifier::Result.new(
        scanned: 1_000,
        updated: 120,
        errors: 0,
        next_after_id: 4567,
        more: true
      )
      refresher = instance_double(VirtualQueueReclassifier, call: result)
      allow(VirtualQueueReclassifier).to receive(:new).and_return(refresher)

      post :refresh_queue_assignments, params: { after_id: "1234" }

      expect(VirtualQueueReclassifier).to have_received(:new).with(
        enabled_queue_names: ["example.queue"],
        after_id: "1234"
      )
      expect(response).to redirect_to(
        admin_queues_path(reclassify_after: 4567, anchor: "queue-configurations")
      )
    end
  end

  describe "admin access" do
    it "does not allow a non-admin to open a queue editor" do
      queue = QueueConfiguration.create!(queue_name: "example.queue")
      non_admin = instance_double(User, admin?: false, time_zone: "UTC")
      allow(controller).to receive(:current_user).and_return(non_admin)

      get :edit_queue, params: { id: queue.id }

      expect(response.body).to eq("Not permitted")
    end
  end

end
