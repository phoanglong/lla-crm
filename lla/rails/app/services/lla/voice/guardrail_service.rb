# frozen_string_literal: true

class Lla::Voice::GuardrailService
  ACTIVE_STATUSES = %w[ringing in_progress].freeze
  CLAIM_TTL = 2.minutes
  DEFAULT_ACCOUNT_CONCURRENCY = 20
  DEFAULT_INBOX_CONCURRENCY = 5
  DEFAULT_USER_CONCURRENCY = 2
  DEFAULT_CALLS_PER_MINUTE = 5
  DEFAULT_ACCOUNT_CALLS_PER_DAY = 1000
  DEFAULT_INBOX_CALLS_PER_DAY = 200

  def initialize(account:, inbox:, user:, destination:, operation:)
    @account = account
    @inbox = inbox
    @user = user
    @destination = destination.to_s
    @operation = operation
  end

  def enforce!
    validate_operation!
    validate_destination!
    validate_kill_switch!
    validate_prefix_policy!
    validate_concurrency!
    validate_daily_volume!
    consume_rate_limit!
    true
  rescue Voice::CallErrors::CallFailed
    raise
  rescue StandardError => e
    Rails.logger.error(
      "LLA_VOICE_GUARDRAIL_UNAVAILABLE account=#{account.id} inbox=#{inbox.id} error=#{e.class.name}"
    )
    raise Voice::CallErrors::CallFailed, 'Voice safety controls are unavailable'
  end

  def self.user_claim_digest(user_id)
    Digest::SHA256.hexdigest("voice-user:#{user_id}")
  end

  private

  attr_reader :account, :inbox, :user, :destination, :operation

  def validate_operation!
    valid = operation.is_a?(Lla::Voice::CallOperation) && operation.account_id == account.id &&
            operation.inbox_id == inbox.id && operation.action == 'dial' && operation.state == 'claimed'
    raise Voice::CallErrors::CallFailed, 'Voice safety operation is invalid' unless valid
  end

  def validate_destination!
    raise Voice::CallErrors::CallFailed, 'Invalid call destination' unless destination.match?(/\A\+[1-9]\d{6,14}\z/)
  end

  def validate_kill_switch!
    global_disabled = GlobalConfigService.load('LLA_VOICE_OUTBOUND_DISABLED', false)
    return unless ActiveModel::Type::Boolean.new.cast(global_disabled) ||
                  ActiveModel::Type::Boolean.new.cast(config['voice_outbound_disabled'])

    raise Voice::CallErrors::CallFailed, 'Outbound calling is disabled'
  end

  def validate_prefix_policy!
    raise Voice::CallErrors::CallFailed, 'Call destination is blocked' if blocked_prefixes.any? { |prefix| destination.start_with?(prefix) }
    return if allowed_prefixes.empty? || allowed_prefixes.any? { |prefix| destination.start_with?(prefix) }

    raise Voice::CallErrors::CallFailed, 'Call destination is outside the allowed regions'
  end

  def validate_concurrency!
    raise_concurrency! if account_concurrency > account_limit
    raise_concurrency! if inbox_concurrency > inbox_limit
    raise_concurrency! if user_concurrency > user_limit
  end

  def account_concurrency
    active_calls.count + claimed_dials.count
  end

  def inbox_concurrency
    active_calls.where(inbox_id: inbox.id).count + claimed_dials.where(inbox_id: inbox.id).count
  end

  def user_concurrency
    calls = active_calls.where(accepted_by_agent_id: user.id).count
    claims = claimed_dials.where(claim_digest: self.class.user_claim_digest(user.id)).count
    calls + claims
  end

  def raise_concurrency!
    raise Voice::CallErrors::CallFailed, 'Voice concurrency limit reached'
  end

  def validate_daily_volume!
    raise Voice::CallErrors::CallFailed, 'Voice daily spend guard reached' if daily_dials.count > account_daily_limit
    raise Voice::CallErrors::CallFailed, 'Voice daily spend guard reached' if
      daily_dials.where(inbox_id: inbox.id).count > inbox_daily_limit
  end

  def consume_rate_limit!
    count = Redis::Alfred.incr(rate_key)
    Redis::Alfred.expire(rate_key, 1.minute.to_i) if count == 1
    return if count <= calls_per_minute

    raise Voice::CallErrors::CallFailed, 'Voice call rate limit reached'
  end

  def active_calls
    @active_calls ||= account.calls.where(status: ACTIVE_STATUSES)
  end

  def claimed_dials
    @claimed_dials ||= Lla::Voice::CallOperation.where(account_id: account.id, action: 'dial', state: 'claimed')
                                                .where('claimed_at > ?', CLAIM_TTL.ago)
  end

  def daily_dials
    @daily_dials ||= Lla::Voice::CallOperation.where(account_id: account.id, action: 'dial')
                                              .where(created_at: Time.current.beginning_of_day..)
  end

  def account_limit
    configured_limit(GlobalConfigService.load('LLA_VOICE_MAX_CONCURRENT_PER_ACCOUNT', DEFAULT_ACCOUNT_CONCURRENCY),
                     DEFAULT_ACCOUNT_CONCURRENCY, 1, 500)
  end

  def inbox_limit
    configured_limit(config['voice_max_concurrent_calls'], DEFAULT_INBOX_CONCURRENCY, 1, 100)
  end

  def user_limit
    configured_limit(config['voice_max_concurrent_calls_per_user'], DEFAULT_USER_CONCURRENCY, 1, 20)
  end

  def calls_per_minute
    configured_limit(config['voice_calls_per_minute'], DEFAULT_CALLS_PER_MINUTE, 1, 100)
  end

  def account_daily_limit
    configured_limit(GlobalConfigService.load('LLA_VOICE_MAX_CALLS_PER_DAY', DEFAULT_ACCOUNT_CALLS_PER_DAY),
                     DEFAULT_ACCOUNT_CALLS_PER_DAY, 1, 100_000)
  end

  def inbox_daily_limit
    configured_limit(config['voice_max_calls_per_day'], DEFAULT_INBOX_CALLS_PER_DAY, 1, 10_000)
  end

  def configured_limit(value, default, minimum, maximum)
    parsed = Integer(value, exception: false) || default
    parsed.clamp(minimum, maximum)
  end

  def allowed_prefixes
    @allowed_prefixes ||= prefixes(config['voice_allowed_destination_prefixes'])
  end

  def blocked_prefixes
    @blocked_prefixes ||= prefixes(config['voice_blocked_destination_prefixes'])
  end

  def prefixes(value)
    values = Array.wrap(value).flat_map { |entry| entry.to_s.split(',') }.map(&:strip).reject(&:blank?)
    raise Voice::CallErrors::CallFailed, 'Voice destination policy is invalid' unless
      values.all? { |prefix| prefix.match?(/\A\+[1-9]\d{0,14}\z/) }

    values.uniq
  end

  def rate_key
    "LLA_VOICE_RATE::#{account.id}:#{inbox.id}:#{user.id}:#{Time.current.utc.strftime('%Y%m%d%H%M')}"
  end

  def config
    @config ||= (inbox.channel.provider_config || {}).to_h
  end
end
