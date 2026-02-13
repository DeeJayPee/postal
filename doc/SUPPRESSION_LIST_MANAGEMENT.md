# Suppression List Management

## Overview

Postal's suppression list feature prevents messages from being sent to addresses that have previously experienced delivery failures. This document describes how to manage the suppression list, including manually removing addresses and releasing held messages.

## What is the Suppression List?

When messages cannot be delivered (due to hard fails or too many soft fails), recipients are automatically added to the suppression list. Future messages to suppressed addresses are held rather than sent, preventing repeated delivery attempts to known bad addresses.

### Automatic Addition

Addresses are added automatically when:
- A recipient experiences multiple hard fails within 24 hours
- A message reaches the maximum number of delivery attempts (soft fails)

### Automatic Removal

By default, addresses are automatically removed after `default_suppression_list_automatic_removal_days` (default: 30 days).

## Manual Suppression List Management

### Viewing the Suppression List

1. Navigate to your server's Messages section
2. Click the "Suppressions" tab
3. View all suppressed addresses with their reason and expiration date

### Removing an Address from the Suppression List

**Via the Web UI:**

1. Go to Messages → Suppressions
2. Find the address you want to remove
3. Click the "Remove from suppression" button
4. Confirm the action in the dialog

When you remove an address from the suppression list:
- The address is immediately removed from the list
- Any held messages for that recipient are automatically released for delivery
- A confirmation message shows how many held messages were released

**Via the API/Console:**

```ruby
# Remove from suppression list
server = Server.find_by(name: "your-server")
server.message_db.suppression_list.remove(:recipient, "user@example.com")

# Release held messages for the recipient
held_messages = server.message_db.messages(
  where: { 
    held: true, 
    scope: "outgoing",
    rcpt_to: "user@example.com" 
  }
)

held_messages.each do |message|
  if message.raw_message?
    message.add_to_message_queue(manual: true)
  end
end
```

## Held Messages

### What Happens to Messages to Suppressed Addresses?

When a message is sent to an address on the suppression list:
1. The message status is set to "Held"
2. A delivery record is created with details: "Recipient (user@example.com) is on the suppression list (reason: too many hard fails)"
3. The message is removed from the queue
4. The raw message is retained (if configured)

### Releasing Held Messages

When you remove an address from the suppression list, all held messages for that recipient are automatically:
1. Added back to the message queue
2. Marked as manual sends (so suppression rules don't immediately re-hold them)
3. Queued for immediate delivery attempt

### Bulk Operations

You can also perform bulk operations on held messages:

**Release all held messages:**
1. Go to Messages → Held
2. Click "Release all messages" to queue all held messages for delivery

**Cancel hold on all messages:**
1. Go to Messages → Held  
2. Click "Cancel hold on all" to stop delivery attempts and mark as failed

**Delete all held messages:**
1. Go to Messages → Held
2. Click "Delete all messages" to permanently remove held messages

## Configuration

### Automatic Removal Period

Configure how long addresses remain suppressed in your `postal.yml`:

```yaml
postal:
  # Number of days an address remains in suppression list (default: 30)
  default_suppression_list_automatic_removal_days: 30
```

### Pruning

Expired suppression entries are automatically pruned daily at 3 AM via a scheduled task (`PruneSuppressionListsScheduledTask`).

## Best Practices

1. **Monitor suppression list growth** - Large suppression lists may indicate delivery issues
2. **Investigate before removing** - Understand why an address was suppressed before removal
3. **Use manual release for testing** - When removing an address, the held message release allows you to verify the address is now deliverable
4. **Regular review** - Periodically review the suppression list for addresses that may have been fixed

## Troubleshooting

### Address keeps getting re-added

If an address is repeatedly added to the suppression list after removal:
- Check the delivery error logs for persistent issues
- Verify the recipient address is correct
- Check if the recipient's mail server has blocked your IP

### Messages not being released

If held messages aren't being released when removing from suppression:
- Check that the messages still have their raw content available
- Verify the message queue is processing
- Check worker logs for any errors

## Technical Details

### Database Schema

The suppression list is stored in each server's message database:

```sql
CREATE TABLE suppressions (
  id INT PRIMARY KEY AUTO_INCREMENT,
  type VARCHAR(255),           -- 'recipient' or 'sender'
  address VARCHAR(255),        -- The email address
  reason VARCHAR(255),         -- Why it was added
  timestamp FLOAT,             -- When it was added
  keep_until FLOAT             -- When it should be auto-removed
);
```

### Code References

- **SuppressionList class**: `lib/postal/message_db/suppression_list.rb`
- **Add to suppression**: `app/lib/message_dequeuer/outgoing_message_processor.rb` (add_recipient_to_suppression_list_on_too_many_hard_fails)
- **Remove from suppression**: `app/lib/message_dequeuer/outgoing_message_processor.rb` (remove_recipient_from_suppression_list_on_success)
- **Hold check**: `app/lib/message_dequeuer/outgoing_message_processor.rb` (hold_if_recipient_on_suppression_list)
- **UI Controller**: `app/controllers/messages_controller.rb` (suppressions, remove_suppression)
- **UI View**: `app/views/messages/suppressions.html.haml`
