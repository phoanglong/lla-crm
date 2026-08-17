# frozen_string_literal: true

# Production-suitable single-flight/coalescing for an expensive cache-miss computation.
#
# The lock lives in the shared cache store via an atomic `write(unless_exist:)`
# (SET NX for Memcached/Redis stores), so concurrent misses across processes/pods
# coalesce onto one computation. The lock has a bounded lifetime, an owner token so
# only the holder releases it, and a fail-safe: if a peer does not publish within the
# wait timeout the waiter computes locally instead of deadlocking. Lock and value keys
# are supplied by the caller and must already be tenant/widget/digest scoped — no raw
# IP ever reaches this layer.
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

    token = SecureRandom.hex(16)
    return compute_as_owner(token, expires_in, &compute) if acquire_lock(token)

    await_peer(expires_in, &compute)
  end

  private

  def compute_as_owner(token, expires_in)
    value = yield
    write_value(value, expires_in.call(value))
    value
  ensure
    release_lock(token)
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

  def acquire_lock(token)
    @cache.write(@lock_key, token, unless_exist: true, expires_in: @lock_ttl)
  end

  def release_lock(token)
    @cache.delete(@lock_key) if @cache.read(@lock_key) == token
  end

  def write_value(value, ttl)
    @cache.write(@value_key, value, expires_in: ttl)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
