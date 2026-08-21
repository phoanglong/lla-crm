# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Voice::GuardrailService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:inbox) { channel.inbox }
  let(:user) { create(:user, account: account) }
  let(:destination) { '+15550001111' }
  let(:operation) do
    Lla::Voice::CallOperation.create!(
      account: account,
      inbox: inbox,
      action: 'dial',
      state: 'claimed',
      idempotency_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      claim_digest: described_class.user_claim_digest(user.id),
      claimed_at: Time.current,
      available_at: Time.current,
      attempts: 1
    )
  end

  before do
    allow(GlobalConfigService).to receive(:load)
      .with('LLA_VOICE_MAX_CONCURRENT_PER_ACCOUNT', described_class::DEFAULT_ACCOUNT_CONCURRENCY)
      .and_return(described_class::DEFAULT_ACCOUNT_CONCURRENCY)
    allow(GlobalConfigService).to receive(:load).with('LLA_VOICE_OUTBOUND_DISABLED', false).and_return(false)
    allow(GlobalConfigService).to receive(:load)
      .with('LLA_VOICE_MAX_CALLS_PER_DAY', described_class::DEFAULT_ACCOUNT_CALLS_PER_DAY)
      .and_return(described_class::DEFAULT_ACCOUNT_CALLS_PER_DAY)
    allow(Redis::Alfred).to receive(:incr).and_return(1)
    allow(Redis::Alfred).to receive(:expire).and_return(true)
  end

  def enforce(**overrides)
    described_class.new(
      account: account,
      inbox: inbox,
      user: user,
      destination: destination,
      operation: operation,
      **overrides
    ).enforce!
  end

  it 'allows a scoped dial within the default safety limits' do
    expect(enforce).to be true
    expect(Redis::Alfred).to have_received(:expire).with(/LLA_VOICE_RATE/, 60)
  end

  it 'rejects a dial operation from another tenant' do
    other_operation = Lla::Voice::CallOperation.new(account: create(:account), inbox: inbox, action: 'dial', state: 'claimed')

    expect { enforce(operation: other_operation) }
      .to raise_error(Voice::CallErrors::CallFailed, 'Voice safety operation is invalid')
  end

  it 'rejects a non-E.164 destination before consuming the rate limit' do
    expect { enforce(destination: '001-555-000-1111') }
      .to raise_error(Voice::CallErrors::CallFailed, 'Invalid call destination')
    expect(Redis::Alfred).not_to have_received(:incr)
  end

  it 'honors the account kill switch' do
    channel.update!(provider_config: channel.provider_config.merge('voice_outbound_disabled' => true))

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Outbound calling is disabled')
  end

  it 'honors the global emergency kill switch' do
    allow(GlobalConfigService).to receive(:load).with('LLA_VOICE_OUTBOUND_DISABLED', false).and_return(true)

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Outbound calling is disabled')
  end

  it 'enforces allowed and blocked destination prefixes' do
    channel.update!(provider_config: channel.provider_config.merge(
      'voice_allowed_destination_prefixes' => ['+1', '+84'],
      'voice_blocked_destination_prefixes' => '+1555'
    ))

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Call destination is blocked')
    expect { enforce(destination: '+442071838750') }
      .to raise_error(Voice::CallErrors::CallFailed, 'Call destination is outside the allowed regions')
  end

  it 'fails closed on malformed destination policy configuration' do
    channel.update!(provider_config: channel.provider_config.merge('voice_allowed_destination_prefixes' => '+1,not-a-prefix'))

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Voice destination policy is invalid')
  end

  it 'enforces the per-user concurrent call limit including the current claim' do
    channel.update!(provider_config: channel.provider_config.merge('voice_max_concurrent_calls_per_user' => 1))
    conversation = create(:conversation, account: account, inbox: inbox)
    create(:call, conversation: conversation, account: account, inbox: inbox,
                  contact: conversation.contact, accepted_by_agent: user, status: 'ringing')

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Voice concurrency limit reached')
  end

  it 'enforces the atomic per-minute rate limit' do
    channel.update!(provider_config: channel.provider_config.merge('voice_calls_per_minute' => 1))
    allow(Redis::Alfred).to receive(:incr).and_return(2)

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Voice call rate limit reached')
  end

  it 'enforces the persistent inbox daily spend proxy' do
    channel.update!(provider_config: channel.provider_config.merge('voice_max_calls_per_day' => 1))
    Lla::Voice::CallOperation.create!(
      account: account,
      inbox: inbox,
      action: 'dial',
      state: 'failed',
      idempotency_digest: Digest::SHA256.hexdigest('prior-dial'),
      request_digest: Digest::SHA256.hexdigest('prior-dial-request'),
      available_at: Time.current
    )

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Voice daily spend guard reached')
  end

  it 'fails closed when the rate limiter is unavailable' do
    allow(Redis::Alfred).to receive(:incr).and_raise(Redis::BaseError)

    expect { enforce }.to raise_error(Voice::CallErrors::CallFailed, 'Voice safety controls are unavailable')
  end
end
