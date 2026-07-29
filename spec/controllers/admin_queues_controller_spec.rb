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
          max_rcpt_per_message: 50,
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
        max_rcpt_per_message: 50,
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
