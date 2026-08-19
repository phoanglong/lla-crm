class ApiController < ApplicationController
  skip_before_action :set_current_user, only: [:index]

  def index
    render json: { product: Lla::ProductVersion.name,
                   version: Lla::ProductVersion.current,
                   compatibility_product: Lla::ProductVersion.compatibility_product,
                   compatibility_version: Lla::ProductVersion.compatibility_version,
                   timestamp: Time.now.utc.to_fs(:db),
                   queue_services: redis_status,
                   data_services: postgres_status }
  end

  private

  # Borrow a pooled connection rather than opening — and never closing — a new one.
  # This endpoint is unauthenticated, so anything that leaks a socket per request
  # leaks it as fast as it is called.
  def redis_status
    Redis::Alfred.with(&:ping) == 'PONG' ? 'ok' : 'failing'
  rescue StandardError => e
    report_unhealthy(:redis, e)
  end

  # Ask the database a question. `connection.active?` reports whether *this thread*
  # has already established a connection, not whether PostgreSQL is reachable:
  # Active Record connects lazily, and this action deliberately skips the
  # authentication that would otherwise have touched the database first. On a
  # freshly started process the answer was "failing" against a perfectly healthy
  # database — observed on the UAT stack, where /api reported failing while the
  # application was serving requests normally.
  def postgres_status
    ActiveRecord::Base.connection.select_value('SELECT 1').to_i == 1 ? 'ok' : 'failing'
  rescue StandardError => e
    report_unhealthy(:postgres, e)
  end

  # A health endpoint has to answer, so every error becomes "failing" rather than a
  # 500. It should still be visible in the logs that something answered that way.
  def report_unhealthy(service, error)
    Rails.logger.warn("[health] #{service} check failed: #{error.class}")
    'failing'
  end
end
