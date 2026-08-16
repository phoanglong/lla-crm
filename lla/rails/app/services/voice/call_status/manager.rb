class Voice::CallStatus::Manager
  pattr_initialize [:call!]

  def process_status_update(status, duration: nil, timestamp: nil)
    return :invalid unless Call::STATUSES.include?(status)

    result = call.transition_to!(
      status,
      occurred_at: timestamp ? Time.zone.at(timestamp) : Time.current,
      duration_seconds: duration
    )
    return result unless result == :applied

    call.conversation.update!(last_activity_at: Time.zone.now)
    # Bump updated_at so the message.updated dispatcher rebroadcasts with the fresh Call embedded.
    call.message&.touch # rubocop:disable Rails/SkipsModelValidations
    result
  end
end
