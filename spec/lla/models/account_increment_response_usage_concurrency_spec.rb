# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account, '.increment_response_usage concurrency', type: :model do
  self.use_transactional_tests = false

  it 'never consumes more than the configured quota under concurrent workers' do
    account = described_class.create!(
      name: "LLA quota concurrency #{SecureRandom.hex(6)}",
      limits: { captain_responses: 2 },
      custom_attributes: { unrelated: 'preserved' }
    )
    barrier = Concurrent::CyclicBarrier.new(4)
    results = Concurrent::Array.new

    workers = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          worker_account = described_class.find(account.id)
          barrier.wait
          results << worker_account.increment_response_usage
        end
      end
    end
    workers.each(&:join)

    expect(results.count(true)).to eq(2)
    expect(results.count(false)).to eq(2)
    expect(account.reload.custom_attributes).to include(
      'captain_responses_usage' => 2,
      'unrelated' => 'preserved'
    )
  ensure
    described_class.where(id: account&.id).delete_all
  end
end
