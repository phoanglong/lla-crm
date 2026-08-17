# frozen_string_literal: true

require 'rails_helper'

# LLA-owned override (Lla::CategoryPolicy). Runs under EE ON and DISABLE_ENTERPRISE=true.
RSpec.describe CategoryPolicy, type: :policy do
  subject(:policy) { described_class }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
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

  permissions :update?, :show?, :edit?, :destroy? do
    it { is_expected.to permit(kb_context, category) }
    it { is_expected.not_to permit(kb_context, cross_tenant_category) }

    it 'denies a forged account_user whose user does not match the context user' do
      forged = { user: create(:user), account: account, account_user: kb_account_user }
      expect(policy).not_to permit(forged, category)
    end
  end
end
