# frozen_string_literal: true

# A voice-enabled Twilio inbox is contactable on the contact's phone number.
#
# The community service only recognises Twilio inboxes whose medium is `sms` or
# `whatsapp`, so a voice inbox silently dropped out of the list of places an agent
# could reach a contact from — while the rest of the LLA voice stack was live.
module Lla::Contacts::ContactableInboxesService
  private

  def get_contactable_inbox(inbox)
    return voice_contactable_inbox(inbox) if voice_inbox?(inbox)

    super
  end

  def voice_inbox?(inbox)
    inbox.channel_type == 'Channel::TwilioSms' && inbox.channel.try(:voice_enabled?)
  end

  def voice_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    { source_id: @contact.phone_number, inbox: inbox }
  end
end
