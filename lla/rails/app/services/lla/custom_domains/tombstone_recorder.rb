# frozen_string_literal: true

# Decides whether a departing hostname leaves an obligation nobody but an operator
# can discharge, and writes the evidence for it.
#
# Two distinct obligations end up here. "There may be a remote object but LLA never
# learned its ID" — the pre-lifecycle import path — and "there is a remote object,
# LLA knows exactly which one, and teardown gave up". A domain LLA itself provisioned
# and tore down successfully leaves neither.
class Lla::CustomDomains::TombstoneRecorder
  Tombstone = Lla::CustomDomains::Tombstone
  LEGACY_REASON = Tombstone::LEGACY_RESOURCE_REASON
  ABANDONED_REASON = Tombstone::ABANDONED_REASON

  # A legacy import that carried a provider status (the only evidence the old
  # implementation left behind) but no resource ID.
  def self.adoption_required?(domain)
    return false if domain.blank?
    return false unless domain.legacy_import?
    return false if domain.provider_resource_id.present?

    domain.provider_status.present?
  end

  def self.record_removal!(domain, now: Time.current)
    return unless adoption_required?(domain)

    record!(account_id: domain.account_id, source_portal_id: domain.portal_id, hostname: domain.hostname,
            reason: LEGACY_REASON, provider_status_hint: domain.provider_status, now: now)
  end

  # Teardown gave up while a *known* remote resource still exists. The resource id is
  # what makes this actionable long after the operation that carried it is purged, so
  # it is persisted with the evidence; only its SHA-256 fingerprint is used for
  # identity and telemetry, so the raw identifier never reaches a key or a log line.
  def self.record_abandoned_teardown!(operation, now: Time.current)
    return if operation.provider_resource_id.blank?
    # No configured provider means no remote object: there is nothing for an
    # operator to delete and therefore nothing to keep evidence of.
    return if operation.provider == 'none'

    record!(account_id: operation.account_id, hostname: operation.hostname,
            reason: ABANDONED_REASON, provider: operation.provider,
            provider_resource_id: operation.provider_resource_id, now: now)
  end

  # Identity is the evidence key, not the hostname: two portals that lost the same
  # hostname are two separate things to fix, two remote resources on one hostname are
  # two objects to delete, and re-reporting the same obligation is a no-op rather
  # than a second row.
  #
  # Re-reporting the same obligation is a no-op, including after an operator resolved
  # it: the reconciler re-reads the same abandoned teardown every tick for as long as
  # the operation is retained, and reopening on each pass would undo the operator's
  # resolution and re-alert forever. A genuinely different obligation — another
  # resource on the same hostname — has a different key and becomes its own item.
  def self.record!(account_id:, hostname:, reason:, source_portal_id: nil, provider: 'none', # rubocop:disable Metrics/ParameterLists
                   provider_resource_id: nil, provider_status_hint: nil, now: Time.current)
    digest = Tombstone.resource_digest_for(provider_resource_id)
    key = Tombstone.evidence_key_for(reason: reason, provider: provider, hostname: hostname,
                                     source_portal_id: source_portal_id, provider_resource_digest: digest)
    tombstone = Tombstone.create_or_find_by!(account_id: account_id, evidence_key: key) do |record|
      record.assign_attributes(portal_id: source_portal_id, source_portal_id: source_portal_id,
                               hostname: hostname, reason: reason, provider: provider,
                               provider_resource_id: provider_resource_id, provider_resource_digest: digest,
                               provider_status_hint: provider_status_hint.presence&.first(64),
                               state: 'manual_adoption_required', created_at: now, updated_at: now)
    end

    announce(tombstone, account_id: account_id, portal_id: source_portal_id, provider: provider, reason: reason)
    tombstone
  end

  # Emitted only by the writer that actually created the record, so a reconciler that
  # re-checks the same outstanding tombstone every tick does not re-alert.
  def self.announce(tombstone, account_id:, portal_id:, provider:, reason:)
    return unless tombstone.previously_new_record?

    Lla::CustomDomains::Telemetry.emit('teardown_manual_adoption', account_id: account_id,
                                                                   portal_id: portal_id,
                                                                   provider: provider,
                                                                   error_code: reason)
  end
  private_class_method :announce
end
