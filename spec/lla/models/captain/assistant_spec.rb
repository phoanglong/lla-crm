require 'rails_helper'

RSpec.describe Captain::Assistant do
  describe '#agent_tools' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    around do |example|
      previous = ENV.fetch(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG, nil)
      ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = 'true'
      example.run
    ensure
      previous.nil? ? ENV.delete(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG) : ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = previous
    end

    it 'includes enabled custom tools from the assistant account' do
      account.enable_features('custom_tools')
      account.save!
      custom_tool = create(:captain_custom_tool, account: account)

      tools = assistant.send(:agent_tools)

      expect(tools.map(&:name)).to include(custom_tool.slug)
      expect(tools.find { |tool| tool.name == custom_tool.slug }).to be_a(Captain::Tools::HttpTool)
    end

    it 'excludes disabled custom tools' do
      account.enable_features('custom_tools')
      account.save!
      custom_tool = create(:captain_custom_tool, :disabled, account: account)

      tools = assistant.send(:agent_tools)

      expect(tools.map(&:name)).not_to include(custom_tool.slug)
    end

    it 'excludes custom tools from other accounts' do
      account.enable_features('custom_tools')
      account.save!
      custom_tool = create(:captain_custom_tool)

      tools = assistant.send(:agent_tools)

      expect(tools.map(&:name)).not_to include(custom_tool.slug)
    end

    it 'keeps the built-in FAQ lookup and handoff tools' do
      tools = assistant.send(:agent_tools)

      expect(tools).to include(
        an_instance_of(Captain::Tools::FaqLookupTool),
        an_instance_of(Captain::Tools::HandoffTool)
      )
    end

    it 'disables custom HTTP tools by default when the feature flag is absent' do
      create(:captain_custom_tool, account: account)
      ENV.delete(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG)

      tools = assistant.send(:agent_tools)

      expect(tools).to contain_exactly(
        an_instance_of(Captain::Tools::FaqLookupTool),
        an_instance_of(Captain::Tools::HandoffTool)
      )
    end

    it 'requires the account custom_tools feature even when the deployment gate is enabled' do
      create(:captain_custom_tool, account: account)

      expect(assistant.send(:agent_tools)).to contain_exactly(
        an_instance_of(Captain::Tools::FaqLookupTool),
        an_instance_of(Captain::Tools::HandoffTool)
      )
    end
  end
end
