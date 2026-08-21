# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User do
  # The seat cap that used to live here read `ChatwootHub.pricing_plan`, a value
  # only Chatwoot's hosted hub writes. Wave J removed the remote plan, and with it
  # the licence check; what remained was an example asserting that a validation
  # which no longer exists does not fire.

  describe 'audit log' do
    # Users are deliberately not audited: the table would fill with rows for every
    # profile edit and none of it is a security-relevant change to an account.
    it 'does not audit user creation' do
      user = create(:user)

      expect(Audited::Audit.where(auditable_type: 'User', auditable_id: user.id).count).to eq(0)
    end
  end
end
