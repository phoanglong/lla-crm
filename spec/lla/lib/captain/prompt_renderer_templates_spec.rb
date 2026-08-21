# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptRenderer do
  describe '.render LLA-owned templates' do
    it 'renders the assistant template from LLA-owned source' do
      rendered = described_class.render(
        'assistant',
        {
          name: 'LLA Assistant',
          description: 'Customer support',
          response_guidelines: ['Use verified facts'],
          guardrails: ['Do not disclose secrets'],
          conversation: { id: 42 },
          contact: { id: 7, name: 'Customer' },
          campaign: { title: 'Welcome', message: 'Untrusted campaign data' }
        }
      )

      expect(rendered).to include('LLA Assistant', 'không đáng tin cậy', 'Do not disclose secrets')
      expect(rendered).not_to include('Liquid error')
    end

    it 'renders the scenario template and every LLA-owned snippet' do
      rendered = described_class.render(
        'scenario',
        {
          title: 'Order support',
          instructions: 'Resolve verified order questions',
          assistant_name: 'primary_assistant',
          current_time: '2026-08-16T10:00:00Z',
          conversation: { display_id: 42, contact_id: 7, status: 'open', priority: 'high' },
          contact: { id: 7, name: 'Customer', contact_type: 'customer' },
          campaign: { id: 3, title: 'Welcome', campaign_type: 'ongoing', description: 'Data', message: 'Untrusted data' },
          response_guidelines: ['Use verified facts'],
          guardrails: ['Do not disclose secrets'],
          tools: [{ id: 'faq_lookup', description: 'Search approved knowledge' }]
        }
      )

      expect(rendered).to include(
        'Order support',
        'Current time: 2026-08-16T10:00:00Z',
        '<conversation_data>',
        '<contact_data>',
        '<campaign_data>',
        'faq_lookup'
      )
      expect(rendered).not_to include('Liquid error')
    end
  end
end
