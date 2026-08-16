require 'rails_helper'

RSpec.describe Captain::CustomToolPolicy, type: :policy do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:administrator_context) do
    { user: administrator, account: account, account_user: administrator.account_users.find_by!(account: account) }
  end
  let(:agent_context) { { user: agent, account: account, account_user: agent.account_users.find_by!(account: account) } }

  shared_examples 'an account-bound Captain configuration policy' do |policy_class, factory|
    let(:record) do
      attributes = { account: account }
      attributes[:assistant] = create(:captain_assistant, account: account) if factory == :captain_scenario
      create(factory, **attributes)
    end
    let(:foreign_record) do
      attributes = { account: other_account }
      attributes[:assistant] = create(:captain_assistant, account: other_account) if factory == :captain_scenario
      create(factory, **attributes)
    end

    it 'allows account members to read only records in their current account' do
      expect(policy_class.new(agent_context, record).show?).to be(true)
      expect(policy_class.new(agent_context, foreign_record).show?).to be(false)
    end

    it 'allows only administrators to mutate records in their current account' do
      expect(policy_class.new(administrator_context, record).update?).to be(true)
      expect(policy_class.new(agent_context, record).update?).to be(false)
      expect(policy_class.new(administrator_context, foreign_record).update?).to be(false)
    end
  end

  it_behaves_like 'an account-bound Captain configuration policy', described_class, :captain_custom_tool

  it 'allows only administrators to create or test through class authorization' do
    expect(described_class.new(administrator_context, Captain::CustomTool).create?).to be(true)
    expect(described_class.new(administrator_context, Captain::CustomTool).test?).to be(true)
    expect(described_class.new(agent_context, Captain::CustomTool).create?).to be(false)
    expect(described_class.new(agent_context, Captain::CustomTool).test?).to be(false)
  end

  context 'with scenario policy' do
    it_behaves_like 'an account-bound Captain configuration policy', Captain::ScenarioPolicy, :captain_scenario

    it 'allows only administrators to create through class authorization' do
      expect(Captain::ScenarioPolicy.new(administrator_context, Captain::Scenario).create?).to be(true)
      expect(Captain::ScenarioPolicy.new(agent_context, Captain::Scenario).create?).to be(false)
    end

    it 'does not expose disabled scenarios to agents' do
      scenario = create(:captain_scenario, account: account, assistant: create(:captain_assistant, account: account), enabled: false)

      expect(Captain::ScenarioPolicy.new(agent_context, scenario).show?).to be(false)
      expect(Captain::ScenarioPolicy.new(administrator_context, scenario).show?).to be(true)
    end
  end
end
