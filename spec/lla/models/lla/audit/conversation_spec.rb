# frozen_string_literal: true

require 'rails_helper'

# This replaces `spec/models/enterprise/audit/conversation_spec.rb`, which had been
# skipping both of its examples since `enterprise/` was deleted:
#
#     skip 'Enterprise audit module not available' unless defined?(Enterprise::Audit::Conversation)
#
# The constant will never be defined again, so the file could only ever report
# "pending" — and it was the only thing that looked like coverage for conversation
# auditing. `Lla::Audit::Conversation` replaced the module and had no spec at all, so
# a security-relevant trail (who deleted which conversation) was untested while the
# suite showed two green-ish pendings over it.
RSpec.describe Lla::Audit::Conversation, type: :model do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }

  it 'is included in Conversation through the LLA extension point' do
    expect(Conversation.ancestors).to include(described_class)
  end

  it 'records an audit row when a conversation is destroyed' do
    conversation

    expect { conversation.destroy! }
      .to change { Audited::Audit.where(auditable_type: 'Conversation', action: 'destroy').count }.by(1)
  end

  it 'stamps the audit with the conversation and its account, so the trail is tenant-scoped' do
    conversation.destroy!

    audit = Audited::Audit.where(auditable_type: 'Conversation', action: 'destroy').last

    expect(audit.auditable_id).to eq(conversation.id)
    expect(audit.associated_id).to eq(account.id)
    expect(audit.associated_type).to eq('Account')
  end

  # `on: %i[destroy]` is the whole contract. Auditing every update would fill the
  # table from the conversation list, which writes on nearly every interaction.
  it 'records nothing for an ordinary update' do
    conversation

    expect { conversation.update!(priority: 'high') }
      .not_to(change { Audited::Audit.where(auditable_type: 'Conversation').count })
  end

  it 'records nothing on create' do
    expect { create(:conversation, account: account) }
      .not_to(change { Audited::Audit.where(auditable_type: 'Conversation').count })
  end
end
