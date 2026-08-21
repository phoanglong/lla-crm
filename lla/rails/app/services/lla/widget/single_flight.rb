# frozen_string_literal: true

# Single-flight/coalescing for an expensive cache-miss computation, across the
# processes and pods of one deployment.
#
# The lock lives in the shared cache store and is taken with an atomic
# `write(unless_exist:)` — SET NX on `RedisCacheStore`, `add` on `MemCacheStore`.
# Whichever caller takes it computes; the others wait for the value it publishes.
#
# Three things this has to get right, and the first version got none of them:
#
# **Every read in the coalescing path bypasses the request-local cache.**
# `ActiveSupport::Cache::Strategy::LocalCache` — mixed into `RedisCacheStore`,
# `MemCacheStore` and `NullStore`, and installed as middleware around every
# request — memoises a *miss*: `LocalStore#fetch_entry` is `@data.fetch(key) {
# @data[key] = yield }`, so the `nil` is stored and returned forever. A waiter
# that missed once never observes the value the owner writes into Redis, and
# every waiter falls through. Measured on ActiveSupport 7.1.5.2 against a real
# Redis: ten concurrent misses produced ten computations with the local cache
# active and one without it.
#
# **A waiter never computes.** Only the lock holder may call the expensive thing.
# A waiter that runs out of budget raises `WaitTimeout`, and the caller applies
# its own documented unavailable policy. That is what makes the bound hard: the
# number of computations in a window is at most one per lock lifetime, whatever
# the number of callers. A fail-safe that computes locally instead — which is
# what the first version did — degrades to exactly the amplification it was
# written to prevent as soon as the provider is slower than the wait budget.
#
# **A waiter whose owner died takes over.** The lock has a bounded life; when it
# is gone the owner has either published (handled by the read) or crashed. One
# waiter re-acquires and becomes the new owner instead of every waiter giving up.
#
# Release is TTL-only: the lock is never actively deleted. `ActiveSupport::Cache`
# exposes no portable atomic compare-and-delete, and a read-then-delete is a
# TOCTOU that lets a stale owner erase a lock a newer owner just took.
#
# Lock and value keys are supplied by the caller and must already be tenant-,
# widget- and digest-scoped: no raw client IP ever reaches this layer.
class Lla::Widget::SingleFlight
  # A peer held the lock for the whole wait budget without publishing. Not an
  # error condition of the computation — the caller decides what an unavailable
  # value means.
  class WaitTimeout < StandardError; end

  # Bounds how long a crashed owner can block its peers, and therefore also the
  # worst-case number of computations: at most one per lock lifetime.
  DEFAULT_LOCK_TTL = 5.seconds
  # Request latency budget for a waiter. Deliberately shorter than the lock TTL:
  # a slow provider must cost one caller its latency, not every caller a
  # duplicate provider call.
  DEFAULT_WAIT_TIMEOUT = 2.seconds
  WAIT_INTERVAL = 0.02

  # A store can only coalesce if `write(unless_exist: true)` is a real conditional
  # write. `NullStore` — which `config/environments/test.rb` configures — returns
  # `true` unconditionally, so every caller believes it owns the lock and nothing
  # is ever cached. Callers that depend on the bound assert this instead of
  # discovering it in production.
  def self.coalescing_capable?(cache)
    probe = "lla:single_flight:capability_probe:#{SecureRandom.hex(8)}"
    first = cache.write(probe, '1', unless_exist: true, expires_in: 5.seconds)
    second = cache.write(probe, '2', unless_exist: true, expires_in: 5.seconds)
    !!first && !second
  rescue StandardError
    false
  ensure
    begin
      cache.delete(probe)
    rescue StandardError
      nil
    end
  end

  def initialize(cache:, value_key:, lock_key:, lock_ttl: DEFAULT_LOCK_TTL, wait_timeout: DEFAULT_WAIT_TIMEOUT)
    @cache = cache
    @value_key = value_key
    @lock_key = lock_key
    @lock_ttl = lock_ttl
    @wait_timeout = wait_timeout
  end

  # Returns the published or computed value, or raises `WaitTimeout`. `expires_in`
  # is a callable mapping the computed value to its TTL, applied by whichever
  # caller performs the computation.
  def call(expires_in:, &)
    cached = read_shared
    return cached unless cached.nil?

    return compute_and_publish(expires_in, &) if acquire_lock

    await_peer(expires_in, &)
  end

  private

  def await_peer(expires_in, &)
    deadline = monotonic_now + @wait_timeout
    while monotonic_now < deadline
      cached = read_shared
      return cached unless cached.nil?
      # The owner's lock expired without a published value: it died. Exactly one
      # waiter takes over; the rest keep waiting on the new owner.
      return compute_and_publish(expires_in, &) if acquire_lock

      sleep(WAIT_INTERVAL)
    end

    raise WaitTimeout
  end

  def compute_and_publish(expires_in)
    value = yield
    write_value(value, expires_in.call(value))
    value
  end

  # Reads the shared store, never the per-request local cache. See the class
  # comment: the local cache memoises misses and would pin a waiter on `nil`.
  def read_shared
    return @cache.read(@value_key) unless @cache.respond_to?(:bypass_local_cache, true)

    @cache.send(:bypass_local_cache) { @cache.read(@value_key) }
  end

  # SET NX with a bounded TTL. The token marks the acquiring owner for
  # observability; the lock is released by TTL expiry only, never by a delete.
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
