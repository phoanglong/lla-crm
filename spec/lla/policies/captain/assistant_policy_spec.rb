# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::AssistantPolicy, type: :policy do
  subject(:assistant_policy) { described_class }

  let(:account) { create(:account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:report_manager) { create(:user, account: account) }
  let(:report_role) { create(:custom_role, account: account, permissions: ['report_manage']) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:administrator_context) do
    { user: administrator, account: account, account_user: account.account_users.find_by!(user_id: administrator.id) }
  end
  let(:agent_context) do
    { user: agent, account: account, account_user: account.account_users.find_by!(user_id: agent.id) }
  end
  let(:report_manager_context) do
    account_user = account.account_users.find_by!(user_id: report_manager.id)
    account_user.update!(custom_role: report_role)
    { user: report_manager, account: account, account_user: account_user }
  end

  permissions :index?, :show?, :playground? do
    context 'when administrator' do
      it { expect(assistant_policy).to permit(administrator_context, assistant) }
    end

    context 'when agent' do
      it { expect(assistant_policy).to permit(agent_context, assistant) }
    end
  end

  permissions :metrics?, :faq_stats?, :summary?, :drilldown? do
    context 'when administrator' do
      it { expect(assistant_policy).to permit(administrator_context, assistant) }
    end

    context 'when agent with report permission' do
      it { expect(assistant_policy).to permit(report_manager_context, assistant) }
    end

    context 'when agent without report permission' do
      it { expect(assistant_policy).not_to permit(agent_context, assistant) }
    end
  end

  permissions :tools?, :create?, :update?, :destroy?, :sync? do
    context 'when administrator' do
      it { expect(assistant_policy).to permit(administrator_context, assistant) }
    end

    context 'when agent' do
      it { expect(assistant_policy).not_to permit(agent_context, assistant) }
    end
  end
end
