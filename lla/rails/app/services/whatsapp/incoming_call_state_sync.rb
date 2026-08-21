# frozen_string_literal: true

class Whatsapp::IncomingCallStateSync
  def initialize(call:)
    @call = call
  end

  def transition!(status, **attributes)
    result = nil
    ActiveRecord::Base.transaction do
      result = call.transition_to!(status, **attributes)
      next if result == :stale

      sync_message_and_conversation!(status, attributes[:duration_seconds])
    end
    result != :stale
  end

  def reconcile!
    ActiveRecord::Base.transaction do
      sync_message_and_conversation!(call.status, call.duration_seconds)
    end
  end

  def delete_sdp
    Lla::Voice::SdpStore.delete(call: call)
  rescue StandardError => e
    Rails.logger.warn(
      "LLA_WHATSAPP_SDP_DELETE_FAILED account=#{call.account_id} inbox=#{call.inbox_id} error=#{e.class.name}"
    )
  end

  private

  attr_reader :call

  def sync_message_and_conversation!(status, duration_seconds)
    Voice::CallMessageBuilder.new(call).update_status!(status: status, agent: call.accepted_by_agent,
                                                       duration_seconds: duration_seconds)
    call.conversation.update!(
      additional_attributes: (call.conversation.additional_attributes || {}).merge(
        'call_status' => call.display_status, 'call_direction' => call.direction_label
      )
    )
  end
end
