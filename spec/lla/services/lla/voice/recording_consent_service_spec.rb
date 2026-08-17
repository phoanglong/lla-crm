# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Voice::RecordingConsentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:call) { create(:call, account: account, inbox: channel.inbox, conversation: conversation) }
  let(:attestation) do
    {
      accepted: true,
      attestation_id: 'recording-attestation-1',
      attested_at: Time.current.iso8601,
      disclosure_version: 'lla-voice-v1',
      method: 'agent_attestation'
    }
  end

  before do
    channel.update!(provider_config: channel.provider_config.merge(
      'voice_recording_enabled' => true,
      'voice_recording_disclosure_version' => 'lla-voice-v1'
    ))
  end

  def capture(target_call: call, payload: attestation, actor: user)
    described_class.new(
      account: account,
      inbox: channel.inbox,
      user: actor,
      call: target_call,
      attestation: payload
    ).capture
  end

  it 'stores only digests and approved policy metadata' do
    consent = capture

    expect(consent).to have_attributes(account_id: account.id, inbox_id: channel.inbox.id, call_id: call.id,
                                       user_id: user.id, capture_method: 'agent_attestation',
                                       disclosure_version: 'lla-voice-v1')
    expect(consent.attestation_digest).to eq(Digest::SHA256.hexdigest('recording-attestation-1'))
    expect(consent.evidence_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(consent.attributes.to_json).not_to include('recording-attestation-1')
  end

  it 'returns the same evidence for an idempotent retry on the same call' do
    first = capture

    expect(capture).to eq(first)
    expect(Lla::Voice::RecordingConsent.count).to eq(1)
  end

  it 'rejects replay of an attestation against another call' do
    capture
    other_conversation = create(:conversation, account: account, inbox: channel.inbox)
    other_call = create(:call, account: account, inbox: channel.inbox, conversation: other_conversation)

    expect(capture(target_call: other_call)).to be_nil
    expect(Lla::Voice::RecordingConsent.count).to eq(1)
  end

  it 'fails closed for a stale disclosure or timestamp' do
    stale_version = attestation.merge(disclosure_version: 'lla-voice-v0')
    stale_time = attestation.merge(attested_at: 1.hour.ago.iso8601)

    expect(capture(payload: stale_version)).to be_nil
    expect(capture(payload: stale_time)).to be_nil
    expect(Lla::Voice::RecordingConsent).not_to exist
  end

  it 'does not create evidence when the inbox policy is disabled' do
    channel.update!(provider_config: channel.provider_config.merge('voice_recording_enabled' => false))

    expect(capture).to be_nil
    expect(Lla::Voice::RecordingConsent).not_to exist
  end
end
