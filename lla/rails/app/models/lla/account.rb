# frozen_string_literal: true

# Mở rộng Account cho năng lực LLA. Được prepend qua
# `Account.prepend_mod_with('Account')` trong app/models/account.rb (MIT).
module Lla::Account
  extend ActiveSupport::Concern

  prepended do
    has_many :custom_roles, dependent: :destroy_async
    has_one :account_saml_settings, dependent: :destroy
    has_many :agent_capacity_policies, dependent: :destroy_async
    has_many :sla_policies, dependent: :destroy_async
    has_many :applied_slas, dependent: :destroy_async
    has_many :companies, dependent: :destroy_async
    has_many :captain_assistants, class_name: 'Captain::Assistant', dependent: :destroy_async
    has_many :captain_documents, class_name: 'Captain::Document', dependent: :destroy_async
    has_many :captain_assistant_responses, class_name: 'Captain::AssistantResponse', dependent: :destroy_async
    has_many :captain_custom_tools, class_name: 'Captain::CustomTool', dependent: :destroy_async
    has_many :captain_faq_suggestions, class_name: 'Captain::FaqSuggestion', dependent: :destroy_async
    has_many :captain_faq_observations, class_name: 'Captain::FaqObservation', dependent: :destroy_async
    has_many :captain_agent_sessions, class_name: 'Captain::AgentSession', dependent: :destroy_async
    has_many :copilot_threads, dependent: :destroy_async
    has_many :lla_captain_quota_ledgers, class_name: 'Lla::Captain::QuotaLedger', dependent: :delete_all
    has_many :lla_knowledge_generation_operations,
             class_name: 'Lla::Knowledge::GenerationOperation', dependent: :delete_all
    has_many :calls, dependent: :destroy_async
    has_many :lla_platform_apps, class_name: 'Lla::PlatformApp', dependent: :destroy_async
    has_many :lla_ai_providers, class_name: 'Lla::Ai::Provider', dependent: :destroy_async

    # Every custom-domain table cascades with `accounts`, and portals are destroyed
    # asynchronously *after* the account row is gone, so a plain delete drops queued
    # provider teardowns and operator evidence while the remote objects they describe
    # keep existing. Exported and refused here, before anything is destroyed, rather
    # than discovered later from a provider bill.
    # See Lla::CustomDomains::AccountDeletionSweep for the contract and its override.
    before_destroy :sweep_lla_custom_domain_obligations, prepend: true

    # `conversation_required_attributes` is declared in the settings JSON schema and
    # permitted by the accounts controller, but the reader lived in an enterprise
    # concern. Without it, `account.conversation_required_attributes` raised
    # NoMethodError — the setting could be written and never read back.
    store_accessor :settings, :conversation_required_attributes
  end

  # The SAML settings row is named `account_saml_settings` here. This is the
  # question callers actually ask, and the only reason the association name
  # mattered anywhere.
  def saml_enabled?
    account_saml_settings.present? && account_saml_settings.saml_enabled?
  end

  # `assignment_v2` and `advanced_assignment` are two names for one capability: the
  # operator toggles the first, and `Lla::Inbox` and the capacity service read the
  # second. Setting one without the other produced an account whose inboxes offered
  # capacity limits that were never enforced.
  #
  # The list arrives from the console as flag names, which may or may not carry the
  # `feature_` prefix depending on the caller, so both spellings are recognised and
  # the companion is added in the same spelling as the flag that implied it.
  def selected_feature_flags=(features)
    features = Array(features).map(&:to_s)
    features |= ['advanced_assignment'] if features.include?('assignment_v2')
    features |= ['feature_advanced_assignment'] if features.include?('feature_assignment_v2')
    super(features)
  end

  # Administrate renders this attribute; the value is not stored on the account.
  def manually_managed_features
    []
  end

  private

  def sweep_lla_custom_domain_obligations
    Lla::CustomDomains::AccountDeletionSweep.call(self)
  end
end
