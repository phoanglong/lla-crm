# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enterprise::PortalPolicy', type: :policy do
  subject(:portal_policy) { PortalPolicy }

  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }

  # Create a custom role with knowledge_base_manage permission
  let(:custom_role) { create(:custom_role, account: account, permissions: ['knowledge_base_manage']) }
  let(:agent_with_role) { create(:user) } # Create without account
  let(:agent_with_role_account_user) do
    create(:account_user, user: agent_with_role, account: account, role: :agent, custom_role: custom_role)
  end
  let(:agent_with_role_context) do
    { user: agent_with_role, account: account, account_user: agent_with_role_account_user }
  end
  let(:other_account) { create(:account) }
  let(:cross_tenant_portal) { create(:portal, account: other_account) }

  permissions :update?, :edit?, :logo? do
    context 'when agent with knowledge_base_manage permission' do
      it { expect(portal_policy).not_to permit(agent_with_role_context, portal) }
    end
  end

  permissions :create?, :destroy? do
    context 'when agent with knowledge_base_manage permission' do
      it { expect(portal_policy).not_to permit(agent_with_role_context, portal) }
    end
  end

  permissions :update?, :edit?, :logo? do
    context 'when policy context user and account_user do not match' do
      let(:mismatched_context) do
        { user: create(:user), account: account, account_user: agent_with_role_account_user }
      end

      it { expect(portal_policy).not_to permit(mismatched_context, portal) }
    end

    context 'when record belongs to another tenant' do
      it { expect(portal_policy).not_to permit(agent_with_role_context, cross_tenant_portal) }
    end
  end
end
