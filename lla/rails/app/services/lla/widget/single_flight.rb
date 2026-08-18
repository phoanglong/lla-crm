# frozen_string_literal: true

# Production-suitable single-flight/coalescing for an expensive cache-miss computation.
#
# The lock lives in the shared cache store via an atomic `write(unless_exist:)`
# (SET NX for Memcached/Redis stores), so concurrent misses across processes/pods
# coalesce onto one computation.
#
# Release is TTL-only: the lock is never actively deleted. ActiveSupport::Cache exposes
# no portable atomic compare-and-delete, and a read-then-delete is a TOCTOU that lets a
# stale owner erase a lock another owner re-acquired after expiry. Instead the bounded
# lock TTL (kept well below the value TTL) frees the lock. A lingering lock cannot
# amplify provider calls because the value cache is read before the lock, and a waiter
# that never sees a published value within the wait timeout computes locally, so there
# is no deadlock. Lock and value keys are supplied by the caller and must already be
# tenant/widget/digest scoped — no raw IP ever reaches this layer.
class Lla::Widget::SingleFlight
  DEFAULT_LOCK_TTL = 5.seconds
  DEFAULT_WAIT_TIMEOUT = 2.seconds
  WAIT_INTERVAL = 0.02

  def initialize(cache:, value_key:, lock_key:, lock_ttl: DEFAULT_LOCK_TTL, wait_timeout: DEFAULT_WAIT_TIMEOUT)
    @cache = cache
    @value_key = value_key
    @lock_key = lock_key
    @lock_ttl = lock_ttl
    @wait_timeout = wait_timeout
  end

  # Returns the published/computed value. `expires_in` is a callable mapping the
  # computed value to its TTL, applied only by whichever caller does the computation.
  def call(expires_in:, &compute)
    cached = @cache.read(@value_key)
    return cached unless cached.nil?

    return compute_as_owner(expires_in, &compute) if acquire_lock

    await_peer(expires_in, &compute)
  end

  private

  def compute_as_owner(expires_in)
    value = yield
    write_value(value, expires_in.call(value))
    value
  end

  def await_peer(expires_in)
    deadline = monotonic_now + @wait_timeout
    while monotonic_now < deadline
      cached = @cache.read(@value_key)
      return cached unless cached.nil?

      sleep(WAIT_INTERVAL)
    end

    # Fail-safe: the owner did not publish in time, so compute locally rather than block.
    value = yield
    write_value(value, expires_in.call(value))
    value
  end

  # SET NX with a bounded TTL. The token marks the acquiring owner for observability;
  # the lock is released by TTL expiry only, never by an active delete.
  def acquire_lock
    @cache.write(@lock_key, SecureRandom.hex(16), unless_exist: true, expires_in: @lock_ttl)
  end

  def write_value(value, ttl)
    @cache.write(@value_key, value, expires_in: ttl)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
