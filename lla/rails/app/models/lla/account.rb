# frozen_string_literal: true

# Mở rộng Account cho năng lực LLA. Được prepend qua
# `Account.prepend_mod_with('Account')` trong app/models/account.rb (MIT).
module Lla::Account
  extend ActiveSupport::Concern

  prepended do
    has_many :custom_roles, dependent: :destroy_async
    has_one :account_saml_settings, dependent: :destroy
    has_many :agent_capacity_policies, dependent: :destroy_async
  end
end
