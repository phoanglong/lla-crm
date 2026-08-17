# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enterprise::ArticlePolicy', type: :policy do
  subject(:article_policy) { ArticlePolicy }

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) } # Needed for author
  let(:portal) { create(:portal, account: account) }
  let(:article) { create(:article, account: account, portal: portal, author: agent) }

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
  let(:cross_tenant_article) { create(:article, account: other_account, portal: create(:portal, account: other_account), author: agent) }

  permissions :index?, :update?, :show?, :edit?, :create?, :destroy?, :reorder? do
    context 'when agent with knowledge_base_manage permission' do
      it { expect(article_policy).to permit(agent_with_role_context, article) }
    end

    context 'when policy context user and account_user do not match' do
      let(:mismatched_context) do
        { user: create(:user), account: account, account_user: agent_with_role_account_user }
      end

      it { expect(article_policy).not_to permit(mismatched_context, article) }
    end

    context 'when custom role belongs to another account' do
      let(:foreign_role) { create(:custom_role, account: other_account, permissions: ['knowledge_base_manage']) }
      let(:forged_account_user) do
        create(:account_user, user: agent_with_role, account: account, role: :agent, custom_role: foreign_role)
      end
      let(:forged_context) do
        { user: agent_with_role, account: account, account_user: forged_account_user }
      end

      it { expect(article_policy).not_to permit(forged_context, article) }
    end

    context 'when record belongs to another tenant' do
      it { expect(article_policy).not_to permit(agent_with_role_context, cross_tenant_article) }
    end
  end
end
