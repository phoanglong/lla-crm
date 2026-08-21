# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Twilio::VoiceLifecycleRepairJob do
  it 'enqueues only channels whose provider lifecycle state needs repair' do
    needs_provision = create(:channel_twilio_sms, :with_voice, twiml_app_sid: nil)
    needs_teardown = create(:channel_twilio_sms, :with_voice)
    needs_teardown.update!(voice_enabled: false)
    healthy = create(:channel_twilio_sms, :with_voice)
    clear_enqueued_jobs

    described_class.perform_now

    expect(Twilio::VoiceLifecycleJob).to have_been_enqueued.with(
      needs_provision.id, 'provision', needs_provision.voice_configuration_digest
    )
    expect(Twilio::VoiceLifecycleJob).to have_been_enqueued.with(
      needs_teardown.id, 'teardown', needs_teardown.voice_configuration_digest
    )
    expect(Twilio::VoiceLifecycleJob).not_to have_been_enqueued.with(
      healthy.id, anything, anything
    )
  end
end
