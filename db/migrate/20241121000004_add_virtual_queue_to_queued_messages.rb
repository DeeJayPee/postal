# frozen_string_literal: true

class AddVirtualQueueToQueuedMessages < ActiveRecord::Migration[7.0]
  def change
    add_column :queued_messages, :virtual_queue, :string
    add_index :queued_messages, :virtual_queue
  end
end
