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

  it 'computes and publishes on a miss, then releases its own lock' do
    result = single_flight.call(expires_in: ttl) { 'US' }
    expect(result).to eq('US')
    expect(cache.read(value_key)).to eq('US')
    expect(cache.read(lock_key)).to be_nil
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

  it 'never releases a lock owned by another holder (owner-token-safe)' do
    cache.write(lock_key, 'another-owner-token', expires_in: 60)
    single_flight(wait_timeout: 0.05).call(expires_in: ttl) { 'x' }
    expect(cache.read(lock_key)).to eq('another-owner-token')
  end
end
