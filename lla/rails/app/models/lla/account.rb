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
    has_many :captain_agent_sessions, class_name: 'Captain::AgentSession', dependent: :destroy_async
    has_many :copilot_threads, dependent: :destroy_async
    has_many :lla_captain_quota_ledgers, class_name: 'Lla::Captain::QuotaLedger', dependent: :delete_all
    has_many :lla_knowledge_generation_operations,
             class_name: 'Lla::Knowledge::GenerationOperation', dependent: :delete_all
    has_many :calls, dependent: :destroy_async

    # Every custom-domain table cascades with `accounts`, and portals are destroyed
    # asynchronously *after* the account row is gone, so a plain delete drops queued
    # provider teardowns and operator evidence while the remote objects they describe
    # keep existing. Exported and refused here, before anything is destroyed, rather
    # than discovered later from a provider bill.
    # See Lla::CustomDomains::AccountDeletionSweep for the contract and its override.
    before_destroy :sweep_lla_custom_domain_obligations, prepend: true
  end

  private

  def sweep_lla_custom_domain_obligations
    Lla::CustomDomains::AccountDeletionSweep.call(self)
  end
end
