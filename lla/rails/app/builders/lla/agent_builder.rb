# frozen_string_literal: true

# An agent invited into an account that authenticates through SAML must be a SAML
# user. Otherwise they are created with a password provider, receive a password
# invitation they cannot complete, and cannot sign in at all — the account's
# identity provider does not know them and the local login refuses them.
module Lla::AgentBuilder
  def perform
    super.tap do |user|
      convert_to_saml_provider(user) if user.try(:persisted?) && account.saml_enabled?
    end
  end

  private

  def convert_to_saml_provider(user)
    user.update!(provider: 'saml') unless user.provider == 'saml'
  end
end
