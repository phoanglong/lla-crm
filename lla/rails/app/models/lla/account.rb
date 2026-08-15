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
  end
end
