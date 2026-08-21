# frozen_string_literal: true

require 'rails_helper'

# LLA-owned override (Lla::CategoryPolicy). Runs identically under EE ON and
# DISABLE_ENTERPRISE=true. Proves the tenant guard wraps both the custom-role grant
# and the base administrator (`super`) result.
RSpec.describe CategoryPolicy, type: :policy do
  subject(:policy) { described_class }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:admin_context) { { user: admin, account: account, account_user: account.account_users.find_by(user: admin) } }
  let(:portal) { create(:portal, account: account) }
  let(:category) { create(:category, account: account, portal: portal, slug: 'g4b-cat') }
  let(:cross_tenant_category) do
    create(:category, account: other_account, portal: create(:portal, account: other_account), slug: 'g4b-other')
  end

  let(:custom_role) { create(:custom_role, account: account, permissions: ['knowledge_base_manage']) }
  let(:kb_agent) { create(:user) }
  let(:kb_account_user) do
    create(:account_user, user: kb_agent, account: account, role: :agent, custom_role: custom_role)
  end
  let(:kb_context) { { user: kb_agent, account: account, account_user: kb_account_user } }

  permissions :index?, :create?, :reorder?, :update?, :show?, :edit?, :destroy? do
    it { is_expected.to permit(admin_context, category) }
    it { is_expected.to permit(kb_context, category) }

    it 'denies a stale account_user whose user does not match the context user' do
      forged = { user: create(:user), account: account, account_user: kb_account_user }
      expect(policy).not_to permit(forged, category)
    end
  end

  permissions :update?, :show?, :edit?, :destroy? do
    it 'denies an administrator against a cross-tenant record' do
      expect(policy).not_to permit(admin_context, cross_tenant_category)
    end

    it 'denies a knowledge_base_manage role against a cross-tenant record' do
      expect(policy).not_to permit(kb_context, cross_tenant_category)
    end

    it 'denies a custom role that belongs to another account' do
      foreign_role = create(:custom_role, account: other_account, permissions: ['knowledge_base_manage'])
      forged_au = build(:account_user, user: kb_agent, account: account, role: :agent)
      forged_au.custom_role = foreign_role
      expect(policy).not_to permit({ user: kb_agent, account: account, account_user: forged_au }, category)
    end
  end
end
