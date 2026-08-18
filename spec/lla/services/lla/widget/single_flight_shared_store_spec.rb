# frozen_string_literal: true

require 'rails_helper'
require 'active_support/cache/redis_cache_store'

# The coalescing proof that matters, run against the kind of store a deployment
# actually uses.
#
# `MemoryStore` is not that store, and the difference is not cosmetic:
# `ActiveSupport::Cache::Strategy::LocalCache` is mixed into `RedisCacheStore`,
# `MemCacheStore` and `NullStore` but NOT into `MemoryStore`, and Rails wraps every
# request in it. `LocalStore#fetch_entry` memoises a miss, so a waiter that reads
# `nil` once keeps reading `nil` for the rest of the request no matter what the
# owner publishes. Measured on this tree before the fix: ten concurrent misses made
# ten computations with the local cache active, one without it. A MemoryStore-only
# suite reports green either way, which is how the defect survived a correction
# round that was supposed to close it.
#
# Redis is already a hard dependency of this test suite, so this is not skipped:
# a skipped concurrency proof is a quarantined one.
RSpec.describe Lla::Widget::SingleFlight, :aggregate_failures do
  let(:redis_url) { ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379') }
  let(:cache) { ActiveSupport::Cache::RedisCacheStore.new(url: "#{redis_url}/12") }
  let(:value_key) { "lla:widget_geo:1:2:#{SecureRandom.hex(6)}" }
  let(:lock_key) { "#{value_key}:lock" }
  let(:ttl) { ->(_value) { 60 } }

  before { cache.clear }

  after { cache.clear }

  def attempt(calls:, provider_seconds:, wait_timeout:)
    described_class.new(cache: cache, value_key: value_key, lock_key: lock_key, wait_timeout: wait_timeout)
                   .call(expires_in: ttl) do
      calls.increment
      sleep provider_seconds
      'VN'
    end
  rescue described_class::WaitTimeout
    :wait_timeout
  end

  def race(threads:, provider_seconds:, local_cache:, wait_timeout: 2.seconds)
    calls = Concurrent::AtomicFixnum.new(0)
    gate = Queue.new
    workers = Array.new(threads) do
      Thread.new do
        gate.pop
        run = -> { attempt(calls: calls, provider_seconds: provider_seconds, wait_timeout: wait_timeout) }
        local_cache ? cache.with_local_cache { run.call } : run.call
      end
    end
    sleep 0.2
    threads.times { gate << :go }
    results = workers.map(&:value)
    [calls.value, results]
  end

  it 'makes exactly one computation for a burst of concurrent misses inside the request-local cache' do
    calls, results = race(threads: 10, provider_seconds: 0.05, local_cache: true)

    expect(calls).to eq(1)
    expect(results).to all(eq('VN'))
  end

  it 'still makes exactly one computation without the request-local cache' do
    calls, results = race(threads: 10, provider_seconds: 0.05, local_cache: false)

    expect(calls).to eq(1)
    expect(results).to all(eq('VN'))
  end

  # The case the previous implementation got backwards: when the computation is
  # slower than a waiter's budget, waiters must give up rather than each make their
  # own call. One computation, and the waiters report unavailable.
  it 'still makes exactly one computation when the provider outlives the wait budget' do
    calls, results = race(threads: 10, provider_seconds: 2.5, local_cache: true, wait_timeout: 1.second)

    expect(calls).to eq(1)
    expect(results).to include('VN')
    expect(results.count(:wait_timeout)).to eq(9)
  end

  it 'reports a real shared store as capable of coalescing' do
    expect(described_class.coalescing_capable?(cache)).to be(true)
  end
end
