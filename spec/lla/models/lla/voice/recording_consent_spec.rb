# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Voice::RecordingConsent do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:call) { create(:call, account: account, inbox: conversation.inbox, conversation: conversation) }

  def consent_attributes
    {
      account: account,
      inbox: call.inbox,
      call: call,
      user: user,
      capture_method: 'agent_attestation',
      disclosure_version: 'lla-voice-v1',
      attestation_digest: Digest::SHA256.hexdigest('attestation'),
      evidence_digest: Digest::SHA256.hexdigest('evidence'),
      actor_reference_digest: Digest::SHA256.hexdigest('actor'),
      client_attested_at: Time.current,
      captured_at: Time.current
    }
  end

  it 'accepts tenant-scoped immutable evidence' do
    consent = described_class.create!(consent_attributes)

    expect(consent.update(disclosure_version: 'lla-voice-v2')).to be false
    expect(consent.errors[:base]).to include('Recording consent evidence is immutable')
    expect { consent.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it 'rejects a user outside the account' do
    consent = described_class.new(consent_attributes.merge(user: create(:user)))

    expect(consent).not_to be_valid
    expect(consent.errors[:user]).to include('must be a live member of the consent account')
  end
end
