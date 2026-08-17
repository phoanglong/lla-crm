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
    domain = lla_custom_domain
    return if domain.blank?

    Lla::CustomDomains::OperationService.enqueue_teardown!(
      account_id: domain.account_id, hostname: domain.hostname, provider: domain.provider,
      provider_resource_id: domain.provider_resource_id, domain_version: domain.version
    )
  end
end
