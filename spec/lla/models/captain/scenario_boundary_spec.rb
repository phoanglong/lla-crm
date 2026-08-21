require 'rails_helper'

RSpec.describe Captain::Scenario, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'derives account ownership from the assistant' do
    scenario = build(:captain_scenario, assistant: assistant, account: create(:account))

    expect(scenario).to be_valid
    expect(scenario.account_id).to eq(account.id)
  end

  it 'rejects oversized scenario input' do
    scenario = build(:captain_scenario, assistant: assistant, account: account,
                                        title: 'x' * 161, instruction: 'x' * 12_001)

    expect(scenario).not_to be_valid
    expect(scenario.errors[:title]).to be_present
    expect(scenario.errors[:instruction]).to be_present
  end

  it 'does not resolve a disabled custom tool at execution time' do
    with_modified_env 'LLA_AI_CUSTOM_HTTP_TOOLS_ENABLED' => 'true' do
      account.enable_features!('custom_tools')
      custom_tool = create(:captain_custom_tool, account: account, slug: 'custom_order')
      scenario = create(:captain_scenario, assistant: assistant, account: account,
                                           instruction: 'Use [Order](tool://custom_order)')
      custom_tool.update!(enabled: false)

      expect(scenario.send(:agent_tools)).to be_empty
    end
  end
end
