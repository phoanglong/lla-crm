# frozen_string_literal: true

# Decides whether a departing hostname needs a manual-adoption record, and writes it.
#
# The distinction that matters is "there was never a remote object" versus "there may
# be one but LLA never learned its ID". Only the second case leaves a tombstone; a
# domain that LLA itself provisioned always has an ID, and a purely local domain has
# nothing remote at all.
class Lla::CustomDomains::TombstoneRecorder
  LEGACY_REASON = 'legacy_provider_resource_unknown'
  ABANDONED_REASON = 'provider_teardown_abandoned'

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

    record!(account_id: domain.account_id, portal_id: domain.portal_id, hostname: domain.hostname,
            reason: LEGACY_REASON, provider_status_hint: domain.provider_status, now: now)
  end

  # Teardown gave up while a *known* remote resource still exists.
  def self.record_abandoned_teardown!(operation, now: Time.current)
    return if operation.provider_resource_id.blank?

    record!(account_id: operation.account_id, portal_id: nil, hostname: operation.hostname,
            reason: ABANDONED_REASON, provider: operation.provider, now: now)
  end

  def self.record!(account_id:, hostname:, reason:, portal_id: nil, provider: 'none', # rubocop:disable Metrics/ParameterLists
                   provider_status_hint: nil, now: Time.current)
    tombstone = Lla::CustomDomains::Tombstone.create_or_find_by!(account_id: account_id, hostname: hostname) do |record|
      record.assign_attributes(portal_id: portal_id, reason: reason, provider: provider,
                               provider_status_hint: provider_status_hint.presence&.first(64),
                               state: 'manual_adoption_required', created_at: now, updated_at: now)
    end

    # Emitted only by the writer that actually created the record, so a reconciler
    # that re-checks the same outstanding tombstone every tick does not re-alert.
    if tombstone.previously_new_record?
      Lla::CustomDomains::Telemetry.emit('teardown_manual_adoption', account_id: account_id,
                                                                     portal_id: portal_id,
                                                                     provider: provider,
                                                                     error_code: reason)
    end
    tombstone
  end
end
