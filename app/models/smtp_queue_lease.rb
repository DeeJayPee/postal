# frozen_string_literal: true

class SMTPQueueLease < ApplicationRecord
  TTL = 5.minutes

  belongs_to :smtp_queue_state
  belongs_to :queued_message, optional: true

  validates :locker, presence: true
  validates :expires_at, presence: true

  scope :active, -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }

  def self.expire_stale!(now = Time.current)
    where("expires_at <= ?", now).find_each do |lease|
      deleted = where(id: lease.id).where("expires_at <= ?", now).delete_all
      next unless deleted == 1

      QueuedMessage.where(locked_by: lease.locker).update_all(locked_by: nil, locked_at: nil)
    end
  end

  def renew!
    update_column(:expires_at, TTL.from_now)
  rescue ActiveRecord::RecordNotFound
    false
  end

  def release!
    destroy!
    true
  rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError
    false
  end
end
