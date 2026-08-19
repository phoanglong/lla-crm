# frozen_string_literal: true

# What has to happen to outstanding remote obligations before a tenant is deleted.
#
# The problem this closes: `lla_custom_domains`, `lla_custom_domain_operations` and
# `lla_custom_domain_tombstones` all cascade with `accounts`, and Chatwoot destroys
# portals asynchronously *after* the account row is gone. So deleting an account
# removes queued teardown snapshots and operator evidence in the same statement,
# and a Cloudflare custom hostname LLA provisioned can outlive the only record that
# it exists. Wave G4a asserted that behaviour rather than fixing it, and left the
# decision open.
#
# The contract here is deliberate and has two halves:
#
# * **Export first.** Whatever happens next, the obligations are written to the
#   operator log before the rows are gone, with the provider resource identifiers
#   that make them actionable. Those identifiers are opaque provider handles, not
#   credentials — they are already stored in plaintext on the rows this is about —
#   and without them the export names an obligation nobody can discharge.
# * **Then refuse.** A tenant with outstanding obligations is not deleted. An
#   operator reaps them (or resolves the tombstones) and deletes again. The refusal
#   is overridable with an explicit environment flag for the case where the remote
#   resources are known to be gone already, and the export still runs on that path.
#
# This costs nothing until custom domains are actually used: with the capability
# OFF there are no lifecycle rows, so there is nothing to sweep and nothing to
# refuse.
class Lla::CustomDomains::AccountDeletionSweep
  class ObligationsOutstanding < StandardError
    attr_reader :code, :count

    def initialize(count)
      @code = 'lla_custom_domain_obligations_outstanding'
      @count = count
      super("#{count} outstanding custom-domain obligation(s) must be resolved before this account is deleted")
    end
  end

  OVERRIDE_FLAG = 'LLA_CUSTOM_DOMAIN_ALLOW_ACCOUNT_DELETION_WITH_OBLIGATIONS'

  def self.call(account)
    new(account).call
  end

  def initialize(account)
    @account = account
  end

  def call
    obligations = collect
    return if obligations.empty?

    export(obligations)
    return if override?

    raise ObligationsOutstanding, obligations.size
  end

  private

  attr_reader :account

  # Three things can still be owed to a provider when a tenant goes away: evidence
  # an operator has not resolved, a teardown that is still queued, and a live
  # domain row that was never released.
  def collect
    outstanding_tombstones + pending_teardowns + live_domains
  end

  def outstanding_tombstones
    Lla::CustomDomains::Tombstone.outstanding.where(account_id: account.id).map do |row|
      { kind: 'tombstone', id: row.id, reason: row.reason, provider: row.provider,
        hostname: row.hostname, provider_resource_id: row.provider_resource_id }
    end
  end

  def pending_teardowns
    Lla::CustomDomains::Operation.where(account_id: account.id, operation_type: 'remove')
                                 .where.not(state: %w[succeeded cancelled])
                                 .where.not(provider_resource_id: [nil, ''])
                                 .map do |row|
      { kind: 'queued_teardown', id: row.id, reason: row.state, provider: row.provider,
        hostname: row.hostname, provider_resource_id: row.provider_resource_id }
    end
  end

  def live_domains
    Lla::CustomDomains::Domain.where(account_id: account.id)
                              .where.not(provider_resource_id: [nil, ''])
                              .map do |row|
      { kind: 'live_domain', id: row.id, reason: row.state, provider: row.provider,
        hostname: row.hostname, provider_resource_id: row.provider_resource_id }
    end
  end

  # The export is the last chance to record these, so it is a warning, not a debug
  # line, and it carries the identifiers rather than digests of them.
  def export(obligations)
    Rails.logger.warn({ event: 'lla_custom_domain_account_deletion_export',
                        account_id: account.id,
                        override: override?,
                        obligations: obligations }.to_json)
    obligations.each do |obligation|
      Lla::CustomDomains::Telemetry.emit('account_deletion_obligation',
                                         account_id: account.id,
                                         provider: obligation[:provider],
                                         error_code: obligation[:kind])
    end
  end

  # Overriding this sweep deletes an account that still owes a provider an action.
  # A destructive override has to be asked for in words that mean yes, not merely in
  # words that are not "no".
  def override?
    ChatwootApp.enabled_flag?(OVERRIDE_FLAG)
  end
end
