require 'rails_helper'

RSpec.describe CallFinder do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  before { create(:inbox_member, user: agent, inbox: inbox) }

  def perform(user, params = {})
    described_class.new(user, account, params).perform
  end

  describe 'visibility' do
    let!(:agent_call) do
      create(:call, account: account, inbox: inbox, conversation: conversation,
                    contact: conversation.contact, accepted_by_agent: agent)
    end
    let!(:other_call) do
      create(:call, account: account, inbox: inbox, conversation: conversation,
                    contact: conversation.contact, accepted_by_agent: admin)
    end

    it 'lets an administrator see every call in the account' do
      result = perform(admin)

      expect(result[:calls].map(&:id)).to contain_exactly(agent_call.id, other_call.id)
    end

    it 'lets a report manager see every call in the account' do
      report_manager = create(:user, account: account, role: :agent)
      custom_role = create(:custom_role, account: account, permissions: ['report_manage'])
      account.account_users.find_by(user_id: report_manager.id).update!(custom_role: custom_role)

      expect(perform(report_manager)[:calls].map(&:id)).to contain_exactly(agent_call.id, other_call.id)
    end

    it 'limits a regular agent to accepted calls in accessible conversations' do
      expect(perform(agent)[:calls].map(&:id)).to contain_exactly(agent_call.id)
    end

    it 'does not trust Current.account_user from another account' do
      other_account = create(:account)
      other_admin = create(:user, account: other_account, role: :administrator)
      Current.account_user = other_account.account_users.find_by(user_id: other_admin.id)

      expect(perform(agent)[:calls].map(&:id)).to contain_exactly(agent_call.id)
    end
  end

  describe 'bounded filters' do
    let!(:ringing) do
      create(:call, account: account, inbox: inbox, conversation: conversation,
                    contact: conversation.contact, status: 'ringing', direction: :incoming,
                    accepted_by_agent: agent)
    end
    let!(:completed) do
      create(:call, account: account, inbox: inbox, conversation: conversation,
                    contact: conversation.contact, status: 'completed', direction: :outgoing,
                    accepted_by_agent: agent, created_at: 10.days.ago)
    end

    it 'normalizes valid status and direction display values' do
      expect(perform(admin, status: 'ringing')[:calls].map(&:id)).to contain_exactly(ringing.id)
      expect(perform(admin, direction: 'outbound')[:calls].map(&:id)).to contain_exactly(completed.id)
    end

    it 'uses a half-open bounded date range' do
      boundary = ringing.created_at.to_i
      result = perform(admin, since: boundary, until: 1.hour.from_now.to_i)

      expect(result[:calls].map(&:id)).to contain_exactly(ringing.id)
    end

    it 'rejects invalid enums, partial ranges and ranges over 90 days' do
      expect { perform(admin, status: 'unknown') }.to raise_error(ActionController::BadRequest)
      expect { perform(admin, direction: 'sideways') }.to raise_error(ActionController::BadRequest)
      expect { perform(admin, since: 1.day.ago.to_i) }.to raise_error(ActionController::BadRequest)
      expect do
        perform(admin, since: 100.days.ago.to_i, until: Time.current.to_i)
      end.to raise_error(ActionController::BadRequest)
    end

    it 'clamps the requested page' do
      result = perform(admin, page: 1_000_000)

      expect(result[:calls].current_page).to eq(CallFinder::MAX_PAGE)
    end
  end

  it 'never returns calls from another account' do
    other_account = create(:account)
    other_conversation = create(:conversation, account: other_account)
    create(:call, account: other_account, inbox: other_conversation.inbox,
                  conversation: other_conversation, contact: other_conversation.contact)

    expect(perform(admin)[:count]).to eq(0)
  end

  it 'loads the finder from the LLA-owned tree' do
    expect(described_class.instance_method(:perform).source_location.first).to include('/lla/rails/')
  end
end
