# frozen_string_literal: true

require 'rails_helper'

# Deterministic concurrency proof for the store-backed single-flight. No DB or Vite;
# runs identically under EE ON and DISABLE_ENTERPRISE=true. The lock is held in the
# cache store (atomic write(unless_exist:) => SET NX in Memcached/Redis), so the
# contract holds across processes/pods, not just within one Ruby process.
RSpec.describe Lla::Widget::SingleFlight do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:value_key) { 'lla:widget_geo:1:2:digest' }
  let(:lock_key) { "#{value_key}:lock" }
  let(:ttl) { ->(_value) { 60 } }

  def single_flight(wait_timeout: 2.seconds)
    described_class.new(cache: cache, value_key: value_key, lock_key: lock_key, wait_timeout: wait_timeout)
  end

  it 'returns a cached value without computing' do
    cache.write(value_key, 'US')
    expect { |probe| single_flight.call(expires_in: ttl, &probe) }.not_to yield_control
  end

  it 'publishes the value on a miss and leaves the lock to expire by TTL (no active delete)' do
    allow(cache).to receive(:delete).and_call_original
    result = single_flight.call(expires_in: ttl) { 'US' }

    expect(result).to eq('US')
    expect(cache.read(value_key)).to eq('US')
    expect(cache).not_to have_received(:delete)
    expect(cache.read(lock_key)).to be_present
  end

  it 'self-expires the lock once the bounded lock TTL elapses' do
    described_class.new(cache: cache, value_key: value_key, lock_key: lock_key,
                        lock_ttl: 5.seconds).call(expires_in: ttl) { 'US' }
    expect(cache.read(lock_key)).to be_present
    travel(6.seconds) { expect(cache.read(lock_key)).to be_nil }
  end

  it 'coalesces a simultaneous miss group onto one computation' do
    count = Concurrent::AtomicFixnum.new(0)
    barrier = Concurrent::CyclicBarrier.new(8)
    results = Queue.new

    Array.new(8) do
      Thread.new do
        barrier.wait
        results << single_flight.call(expires_in: ttl) { count.increment && sleep(0.05) && 'US' }
      end
    end.each(&:join)

    expect(count.value).to eq(1)
    expect(Array.new(results.size) { results.pop }).to all(eq('US'))
  end

  it 'does not let a different key block or coalesce a distinct computation' do
    count = Concurrent::AtomicFixnum.new(0)
    described_class.new(cache: cache, value_key: 'a', lock_key: 'a:lock').call(expires_in: ttl) { count.increment && 'A' }
    described_class.new(cache: cache, value_key: 'b', lock_key: 'b:lock').call(expires_in: ttl) { count.increment && 'B' }
    expect(count.value).to eq(2)
  end

  it 'fails safe by computing locally when a peer never publishes within the timeout' do
    cache.write(lock_key, 'stuck-owner-token', expires_in: 60)
    result = single_flight(wait_timeout: 0.1).call(expires_in: ttl) { 'computed-locally' }
    expect(result).to eq('computed-locally')
  end

  # Regression for the read-then-delete TOCTOU on commit 3786779: owner A read its own
  # token, owner B re-acquired after A's TTL expired, then A's unconditional delete erased
  # B's lock. The owner path must issue no delete on the lock key, so A can never remove a
  # lock held by B. Fails on 3786779; passes on the TTL-only release.
  it 'never deletes a lock re-acquired by another owner during the release window' do
    allow(cache).to receive(:delete).and_call_original
    injected = false
    allow(cache).to receive(:read).and_wrap_original do |original, key, *rest|
      value = original.call(key, *rest)
      if !injected && key == lock_key && value.present?
        injected = true
        cache.write(lock_key, 'owner-b-token', expires_in: 60)
      end
      value
    end

    single_flight.call(expires_in: ttl) { 'US' }

    expect(cache).not_to have_received(:delete)
  end

  describe 'against a real RedisCacheStore (multi-pod store contract)' do
    let(:namespace) { "g4b-sf-#{SecureRandom.hex(6)}" }
    let(:redis_cache) do
      ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379'), namespace: namespace)
    end

    before do
      redis_cache.write('__ping__', '1', expires_in: 5)
    rescue StandardError => e
      skip("Redis unavailable for the multi-pod single-flight contract: #{e.class}")
    end

    after do
      redis_cache.delete_matched('*')
    rescue StandardError
      nil
    end

    it 'lets exactly one concurrent owner acquire the SET NX lock' do
      winners = Concurrent::AtomicFixnum.new(0)
      barrier = Concurrent::CyclicBarrier.new(8)

      Array.new(8) do
        Thread.new do
          barrier.wait
          winners.increment if redis_cache.write(lock_key, SecureRandom.hex(8), unless_exist: true, expires_in: 5)
        end
      end.each(&:join)

      expect(winners.value).to eq(1)
    end

    it 'self-expires the lock by TTL rather than an active delete (owner cannot erase a peer lock)' do
      allow(redis_cache).to receive(:delete).and_call_original
      described_class.new(cache: redis_cache, value_key: value_key, lock_key: lock_key,
                          lock_ttl: 1.second).call(expires_in: ttl) { 'US' }

      expect(redis_cache).not_to have_received(:delete)
      expect(redis_cache.read(lock_key)).to be_present
      sleep(1.3)
      expect(redis_cache.read(lock_key)).to be_nil
    end
  end
end
