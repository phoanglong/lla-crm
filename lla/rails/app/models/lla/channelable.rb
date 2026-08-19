# frozen_string_literal: true

# Audit every change to a channel's configuration against its inbox.
#
# A channel row holds the credentials and provider configuration an inbox runs on.
# Changing one changes what the inbox does and who it talks to, and the record of
# that change lived only in an enterprise concern — so with enterprise off, channel
# credentials could be rewritten with nothing written down.
module Lla::Channelable
  extend ActiveSupport::Concern

  # `ActiveSupport::Concern#included` would place these *after* the community
  # methods in the lookup chain, and the method being replaced is defined there.
  # Prepending explicitly is what puts this first.
  included do
    prepend InstanceMethods
  end

  module InstanceMethods
    # `secret` is excluded because an audit row that records a credential is a
    # credential store; `updated_at` because it changes on every write and would
    # make every audit row look like a change.
    IGNORED_COLUMNS = %w[updated_at secret].freeze

    def create_audit_log_entry
      return if inbox.nil?

      changes = saved_changes.except(*IGNORED_COLUMNS)
      return if changes.blank?
      return if messaging_template_updates?(changes)

      Lla::AuditLog.create(
        auditable_id: inbox.id,
        auditable_type: 'Inbox',
        action: 'update',
        associated_id: account.id,
        associated_type: 'Account',
        audited_changes: changes
      )
    end

    # WhatsApp writes `message_templates_last_updated` on a schedule. Auditing it
    # would bury real configuration changes under a periodic entry that no operator
    # made.
    def messaging_template_updates?(changes)
      changes.keys == ['message_templates_last_updated']
    end
  end
end
