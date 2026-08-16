# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetConversationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account) }
  let(:allowed_inbox) { create(:inbox, account: account) }
  let(:blocked_inbox) { create(:inbox, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before { allowed_inbox.members << user }

  it 'does not expose a same-account conversation outside the user inbox scope' do
    allowed = create(:conversation, account: account, inbox: allowed_inbox)
    blocked = create(:conversation, account: account, inbox: blocked_inbox)

    expect(service.execute(conversation_id: allowed.display_id)).to include("Conversation ID: ##{allowed.display_id}")
    expect(service.execute(conversation_id: blocked.display_id)).to eq('Conversation not found')
  end

  it 'bounds a direct article result before returning it to the model' do
    administrator = create(:user, :administrator, account: account)
    article = create(:article, account: account)
    allow(Article).to receive(:find_by).with(id: article.id, account_id: account.id).and_return(article)
    allow(article).to receive(:to_llm_text).and_return('x' * 50_000)
    article_service = Captain::Tools::Copilot::GetArticleService.new(assistant, user: administrator)

    expect(article_service.execute(article_id: article.id).bytesize)
      .to be <= Captain::Tools::PermissionHelpers::MAX_OUTPUT_BYTES
  end
end
