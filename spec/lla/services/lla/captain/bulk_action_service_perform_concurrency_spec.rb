# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::BulkActionService, '.perform concurrency', type: :model do
  self.use_transactional_tests = false

  it 'executes one operation id at most once across concurrent workers' do
    account = Account.create!(name: "LLA bulk concurrency #{SecureRandom.hex(6)}")
    user = create(:user, account: account, role: :administrator)
    assistant = create(:captain_assistant, account: account)
    response = create(:captain_assistant_response, account: account, assistant: assistant)
    barrier = Concurrent::CyclicBarrier.new(2)
    results = Concurrent::Array.new

    workers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          results << perform_operation(account.id, user.id, response.id)
        rescue StandardError => e
          results << e.class
        end
      end
    end
    workers.each(&:join)

    aggregate_failures do
      expect(Captain::AssistantResponse.exists?(response.id)).to be(false)
      expect(Lla::Captain::BulkOperation.where(account_id: account.id).count).to eq(1)
      expect(results.count { |result| result.is_a?(Hash) && result[:success] }).to be_between(1, 2)
      expect(results - [Lla::Captain::BulkActionService::InProgress]).to all(be_a(Hash))
    end
  ensure
    Account.where(id: account&.id).destroy_all
  end

  private

  def perform_operation(account_id, user_id, response_id)
    described_class.new(
      account: Account.find(account_id),
      user: User.find(user_id),
      resource_type: 'AssistantResponse',
      action: 'delete',
      ids: [response_id],
      operation_id: 'shared-operation'
    ).perform
  end
end
