require 'rails_helper'

RSpec.describe Account, type: :model do
  include ActiveJob::TestHelper

  describe 'associations' do
    it { is_expected.to have_many(:sla_policies).dependent(:destroy_async) }
    it { is_expected.to have_many(:applied_slas).dependent(:destroy_async) }
  end

  describe 'sla_policies' do
    let!(:account) { create(:account) }
    let!(:sla_policy) { create(:sla_policy, account: account) }

    it 'returns associated sla policies' do
      expect(account.sla_policies).to eq([sla_policy])
    end

    it 'deletes associated sla policies' do
      perform_enqueued_jobs do
        account.destroy!
      end
      expect { sla_policy.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
