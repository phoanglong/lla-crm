# frozen_string_literal: true

# Connection options for the shared Rails cache store.
#
# Top-level on purpose: `config/environments/*.rb` is evaluated while the
# application is still being defined, before `lib/` is autoloadable and before
# `config/initializers/01_redis.rb` has run, so it can neither reach `Redis::Config`
# nor reopen a namespace that does not exist yet. This duplicates only the
# connection inputs — read from the same environment variables as every other Redis
# client here — rather than hardcoding a URL in two environment files.
module LlaCacheStoreConfig
  module_function

  def options
    {
      url: ENV.fetch('LLA_CACHE_REDIS_URL', nil).presence || ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379'),
      password: ENV.fetch('REDIS_PASSWORD', nil).presence,
      reconnect_attempts: 2,
      connect_timeout: 1,
      read_timeout: 1,
      write_timeout: 1
    }.compact
  end
end
