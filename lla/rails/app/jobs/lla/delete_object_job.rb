# frozen_string_literal: true

# Object deletion, extended for the associations and the audit trail LLA owns.
module Lla::DeleteObjectJob
  private

  # An SLA policy can carry a very large number of applied SLAs. Without this the
  # cascade runs row by row inside the delete, which is how a routine policy
  # deletion becomes a long transaction.
  def heavy_associations
    super.merge(SlaPolicy => %i[applied_slas]).freeze
  end

  def process_post_deletion_tasks(object, user, ip)
    create_audit_entry(object, user, ip)
  end

  # Deleting an inbox, a conversation or an SLA policy is exactly the kind of act
  # an audit log exists for, and it is the one act the record itself cannot answer
  # for afterwards.
  AUDITED_TYPES = %w[Inbox Conversation SlaPolicy].freeze

  def create_audit_entry(object, user, ip)
    return if user.blank?
    return unless AUDITED_TYPES.include?(object.class.to_s)

    Lla::AuditLog.create(
      auditable: object,
      audited_changes: object.attributes,
      action: 'destroy',
      user: user,
      associated: object.account,
      remote_address: ip
    )
  end
end
