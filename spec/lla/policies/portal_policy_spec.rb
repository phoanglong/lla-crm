# frozen_string_literal: true

require 'rails_helper'

# LLA-owned override (Lla::PortalPolicy). knowledge_base_manage is content-only and must
# not grant portal settings / custom-domain / DNS write. Runs under EE ON and EE OFF.
RSpec.describe PortalPolicy, type: :policy do
  subject(:policy) { described_class }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:admin_context) { { user: admin, account: account, account_user: account.account_users.find_by(user: admin) } }
  let(:portal) { create(:portal, account: account) }
  let(:cross_tenant_portal) { create(:portal, account: other_account) }

  let(:custom_role) { create(:custom_role, account: account, permissions: ['knowledge_base_manage']) }
  let(:kb_agent) { create(:user) }
  let(:kb_account_user) do
    create(:account_user, user: kb_agent, account: account, role: :agent, custom_role: custom_role)
  end
  let(:kb_context) { { user: kb_agent, account: account, account_user: kb_account_user } }

  permissions :update?, :edit?, :logo? do
    it 'permits an administrator within the account' do
      expect(policy).to permit(admin_context, portal)
    end

    it 'denies a knowledge_base_manage custom role' do
      expect(policy).not_to permit(kb_context, portal)
    end

    it 'denies an administrator against a cross-tenant portal record' do
      expect(policy).not_to permit(admin_context, cross_tenant_portal)
    end
  end
end
