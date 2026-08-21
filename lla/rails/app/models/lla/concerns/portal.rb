# frozen_string_literal: true

# LLA replacement for the Chatwoot Cloud only `Enterprise::Concerns::Portal`.
#
# Differences that matter: the hostname is canonicalised and validated on create
# *and* update, the lifecycle is driven for every deployment (not just Chatwoot
# Cloud), and changing or clearing the domain schedules a provider teardown
# instead of silently orphaning a remote hostname.
module Lla::Concerns::Portal
  extend ActiveSupport::Concern

  included do
    has_one :lla_custom_domain, class_name: 'Lla::CustomDomains::Domain',
                                foreign_key: :portal_id, inverse_of: :portal, dependent: :destroy
    # Evidence outlives the portal it is about. Deleting the portal detaches the live
    # reference and keeps `source_portal_id`, so the work list still names the portal
    # an operator has to reason about while PostgreSQL never holds a dangling one —
    # the composite tenant foreign key refuses a portal delete that would orphan it.
    has_many :lla_custom_domain_tombstones, class_name: 'Lla::CustomDomains::Tombstone',
                                            foreign_key: :portal_id, inverse_of: :portal,
                                            dependent: :nullify

    before_validation :canonicalize_lla_custom_domain
    after_save :synchronize_lla_custom_domain, if: :saved_change_to_custom_domain?
    before_destroy :enqueue_lla_custom_domain_teardown, prepend: true
  end

  def custom_domain_state
    lla_custom_domain&.state
  end

  def custom_domain_active?
    lla_custom_domain&.active? || false
  end

  private

  def canonicalize_lla_custom_domain
    return if custom_domain.blank?

    self.custom_domain = Lla::CustomDomains::HostCanonicalizer.from_user_input(custom_domain)
  rescue Lla::CustomDomains::HostCanonicalizer::InvalidHost => e
    errors.add(:custom_domain, e.code)
  end

  def synchronize_lla_custom_domain
    Lla::CustomDomains::LifecycleService.new(portal: self).synchronize!(custom_domain)
    association(:lla_custom_domain).reset
  rescue Lla::CustomDomains::LifecycleService::InvalidRequest => e
    errors.add(:custom_domain, e.code)
    raise ActiveRecord::RecordInvalid, self
  end

  # `dependent: :destroy` removes the row; the remote resource still has to go.
  def enqueue_lla_custom_domain_teardown
    # Read straight from the table: the association may be cached from before the
    # lifecycle row existed, and losing it here would lose the teardown evidence.
    domain = Lla::CustomDomains::Domain.find_by(portal_id: id)
    return if domain.blank?

    Lla::CustomDomains::OperationService.enqueue_teardown!(
      account_id: domain.account_id, hostname: domain.hostname, provider: domain.provider,
      provider_resource_id: domain.provider_resource_id, domain_version: domain.version
    )
    # A legacy import may still own a remote object whose ID LLA never learned; the
    # portal going away must not erase that fact.
    Lla::CustomDomains::TombstoneRecorder.record_removal!(domain)
  end
end
