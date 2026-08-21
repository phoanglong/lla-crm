# frozen_string_literal: true

require 'rails_helper'

# LLA-owned override (Lla::PortalPolicy). knowledge_base_manage keeps portal content
# management (matching the community contract), but every result is wrapped in the
# tenant guard. Custom-domain/DNS lifecycle stays with the G4a portal concern.
# Runs identically under EE ON and DISABLE_ENTERPRISE=true.
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

    it 'permits a knowledge_base_manage custom role for portal content' do
      expect(policy).to permit(kb_context, portal)
    end

    it 'denies an administrator against a cross-tenant portal record' do
      expect(policy).not_to permit(admin_context, cross_tenant_portal)
    end

    it 'denies a knowledge_base_manage role against a cross-tenant portal record' do
      expect(policy).not_to permit(kb_context, cross_tenant_portal)
    end

    it 'denies a stale account_user whose user does not match the context user' do
      forged = { user: create(:user), account: account, account_user: kb_account_user }
      expect(policy).not_to permit(forged, portal)
    end
  end

  permissions :create?, :destroy? do
    it 'restricts portal creation/deletion to administrators' do
      expect(policy).not_to permit(kb_context, portal)
    end
  end
end
