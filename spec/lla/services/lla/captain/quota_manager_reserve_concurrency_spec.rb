# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::QuotaManager, '.reserve! concurrency', type: :model do
  self.use_transactional_tests = false

  def build_manager(account, key, owner)
    described_class.new(
      account: account,
      idempotency_key: key,
      owner_token: owner,
      feature: 'editor',
      provider: 'openai',
      credential_source: 'system',
      reason: 'concurrency_spec'
    )
  end

  it 'never reserves more units than the account plan under concurrent workers' do
    account = Account.create!(name: "LLA ledger concurrency #{SecureRandom.hex(6)}", limits: { captain_responses: 2 })
    barrier = Concurrent::CyclicBarrier.new(4)
    results = Concurrent::Array.new

    workers = Array.new(4) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          worker_account = Account.find(account.id)
          barrier.wait
          results << build_manager(worker_account, "request-#{index}", "worker-#{index}").reserve!.status
        end
      end
    end
    workers.each(&:join)

    expect(results.count(:acquired)).to eq(2)
    expect(results.count(:rejected)).to eq(2)
    expect(account.lla_captain_quota_ledgers.sole.reload.reserved_units).to eq(2)
  ensure
    Account.where(id: account&.id).destroy_all
  end

  it 'allows only one owner to acquire a concurrent idempotency key' do
    account = Account.create!(name: "LLA idempotency concurrency #{SecureRandom.hex(6)}", limits: { captain_responses: 5 })
    barrier = Concurrent::CyclicBarrier.new(4)
    results = Concurrent::Array.new

    workers = Array.new(4) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          worker_account = Account.find(account.id)
          barrier.wait
          results << build_manager(worker_account, 'same-request', "worker-#{index}").reserve!.status
        end
      end
    end
    workers.each(&:join)

    expect(results.count(:acquired)).to eq(1)
    expect(results.count(:duplicate_in_flight)).to eq(3)
    expect(account.lla_captain_quota_ledgers.sole.reload.reserved_units).to eq(1)
  ensure
    Account.where(id: account&.id).destroy_all
  end
end
