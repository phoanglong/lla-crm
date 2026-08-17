# frozen_string_literal: true

require 'rails_helper'

# LLA-owned override (Lla::ArticlePolicy). Runs under EE ON and DISABLE_ENTERPRISE=true.
RSpec.describe ArticlePolicy, type: :policy do
  subject(:policy) { described_class }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:author) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:article) { create(:article, account: account, portal: portal, author: author) }
  let(:cross_tenant_article) do
    create(:article, account: other_account, portal: create(:portal, account: other_account), author: author)
  end

  let(:custom_role) { create(:custom_role, account: account, permissions: ['knowledge_base_manage']) }
  let(:kb_agent) { create(:user) }
  let(:kb_account_user) do
    create(:account_user, user: kb_agent, account: account, role: :agent, custom_role: custom_role)
  end
  let(:kb_context) { { user: kb_agent, account: account, account_user: kb_account_user } }

  permissions :update?, :show?, :edit?, :destroy? do
    it { is_expected.to permit(kb_context, article) }
    it { is_expected.not_to permit(kb_context, cross_tenant_article) }

    it 'denies a forged account_user whose user does not match the context user' do
      forged = { user: create(:user), account: account, account_user: kb_account_user }
      expect(policy).not_to permit(forged, article)
    end

    it 'denies a custom role that belongs to another account' do
      # AccountUser persistence already forbids a cross-account custom_role, so assign it
      # in memory to prove the policy independently re-checks the tenant boundary.
      foreign_role = create(:custom_role, account: other_account, permissions: ['knowledge_base_manage'])
      forged_au = build(:account_user, user: kb_agent, account: account, role: :agent)
      forged_au.custom_role = foreign_role
      expect(policy).not_to permit({ user: kb_agent, account: account, account_user: forged_au }, article)
    end
  end
end
