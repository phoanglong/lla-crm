require 'rails_helper'

RSpec.describe Call do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) do
    create(:call, account: account, inbox: inbox, conversation: conversation,
                  contact: conversation.contact, status: 'ringing')
  end

  it 'loads the model from the LLA-owned tree' do
    expect(described_class.instance_method(:transition_to!).source_location.first).to include('/lla/rails/')
  end

  it 'rejects cross-tenant and cross-conversation associations' do
    other_account = create(:account)
    other_conversation = create(:conversation, account: other_account)
    invalid = build(:call, account: account, inbox: other_conversation.inbox,
                           conversation: other_conversation, contact: other_conversation.contact)

    expect(invalid).not_to be_valid
    expect(invalid.errors.attribute_names).to include(:inbox, :conversation, :contact)
  end

  it 'rejects a message outside the call conversation' do
    message = create(:message, account: account, inbox: inbox)
    invalid = build(:call, account: account, inbox: inbox, conversation: conversation,
                           contact: conversation.contact, message: message)

    expect(invalid).not_to be_valid
    expect(invalid.errors[:message]).to include('must belong to the call conversation')
  end

  it 'rejects an accepted agent without account membership' do
    outsider = create(:user)
    call.accepted_by_agent = outsider

    expect(call).not_to be_valid
    expect(call.errors[:accepted_by_agent]).to include('must belong to the call account')
  end

  it 'applies monotonic transitions and derives duration' do
    start = 5.minutes.ago.change(usec: 0)

    expect(call.transition_to!('in_progress', occurred_at: start)).to eq(:applied)
    expect(call.transition_to!('completed', occurred_at: start + 2.minutes)).to eq(:applied)
    expect(call.reload).to have_attributes(status: 'completed', duration_seconds: 120)
    expect(call.transition_to!('ringing')).to eq(:stale)
    expect(call.reload.status).to eq('completed')
  end

  it 'treats duplicate transitions idempotently and preserves the earliest start' do
    later = 2.minutes.ago.change(usec: 0)
    earlier = 3.minutes.ago.change(usec: 0)
    call.transition_to!('in_progress', occurred_at: later)

    expect(call.transition_to!('in_progress', occurred_at: earlier)).to eq(:duplicate)
    expect(call.reload.started_at.to_i).to eq(earlier.to_i)
  end

  it 'reads the legacy meta end timestamp during provider migration' do
    timestamp = 1.minute.ago.change(usec: 0)
    call.update!(meta: call.meta.merge('ended_at' => timestamp.to_i))

    expect(call.reload.ended_at.to_i).to eq(timestamp.to_i)
  end

  it 'does not coerce an invalid legacy end timestamp to the Unix epoch' do
    call.update!(meta: call.meta.merge('ended_at' => 'invalid'))

    expect(call.reload.ended_at).to be_nil
  end

  it 'redacts sensitive data from realtime event payloads' do
    call.update!(transcript: 'synthetic transcript')

    expect(call.push_event_data).not_to include(:from_number, :to_number, :transcript, :recording_url, :conference_sid)
  end

  it 'filters unsafe ICE URLs and falls back to the controlled STUN default' do
    ClimateControl.modify VOICE_CALL_STUN_URLS: 'http://169.254.169.254,turn:user:pass@example.com' do
      expect(described_class.default_ice_servers).to eq([{ urls: [Call::DEFAULT_STUN_URL] }])
    end
  end

  it 'allows the same provider identity in another tenant while rejecting a duplicate in one inbox' do
    duplicate = build(:call, account: account, inbox: inbox, conversation: conversation,
                             contact: conversation.contact, provider_call_id: call.provider_call_id)
    other_conversation = create(:conversation)
    other = build(:call, account: other_conversation.account, inbox: other_conversation.inbox,
                         conversation: other_conversation, contact: other_conversation.contact,
                         provider_call_id: call.provider_call_id)

    expect(duplicate).not_to be_valid
    expect(other).to be_valid
  end

  it 'validates event and operation tenant boundaries without storing provider payloads' do
    digest = 'a' * 64
    event = Lla::Voice::CallEvent.new(account: account, inbox: inbox, call: call, provider: :twilio,
                                      event_id_digest: digest, payload_digest: digest,
                                      event_type: 'status', verified_at: Time.current)
    operation = Lla::Voice::CallOperation.new(account: account, inbox: inbox, call: call, action: 'dial',
                                              idempotency_digest: digest, request_digest: digest,
                                              available_at: Time.current)

    expect(event).to be_valid
    expect(operation).to be_valid
    expect(event.attributes.keys).not_to include('payload')
    expect(operation.attributes.keys).not_to include('request_payload')
  end
end
