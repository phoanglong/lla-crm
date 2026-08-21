class Whatsapp::IncomingCallService
  pattr_initialize [:inbox!, :params!]

  def perform
    return unless inbox.channel.voice_enabled? && inbox.account.feature_enabled?('channel_voice')

    Whatsapp::IncomingCallPayload.entries(params[:calls]).each { |entry| handle_event(entry.with_indifferent_access) }
    Whatsapp::IncomingCallPayload.entries(params[:statuses]).each { |entry| handle_status(entry.with_indifferent_access) }
  end

  private

  def handle_event(payload)
    Whatsapp::IncomingCallPayload.validate_call_id!(payload[:id])
    case payload[:event]
    when 'connect' then handle_connect(payload)
    when 'terminate' then handle_terminate(payload)
    else Rails.logger.warn "LLA_WHATSAPP_CALL_EVENT_IGNORED account=#{inbox.account_id} inbox=#{inbox.id} type=unknown"
    end
  end

  # Meta's `connect` event for outbound calls fires when the WebRTC tunnel is
  # up — empirically ~20s before the contact actually answers. The real pickup
  # is reported as a separate webhook with status=ACCEPTED, and is what
  # `terminate.start_time` aligns to. Treat ACCEPTED as the pickup transition.
  def handle_status(payload)
    return unless payload[:type] == 'call'

    Whatsapp::IncomingCallPayload.validate_call_id!(payload[:id])
    call = call_scope.find_by(provider_call_id: payload[:id])
    return unless call

    case payload[:status]
    when 'ACCEPTED' then mark_outbound_accepted(call, payload)
    when 'RINGING' then nil # informational
    else Rails.logger.info "LLA_WHATSAPP_CALL_STATUS_IGNORED account=#{inbox.account_id} inbox=#{inbox.id}"
    end
  end

  # The model transition is compare-and-set, so a webhook racing with an agent
  # action cannot overwrite a freshly-finalized terminal status.
  def mark_outbound_accepted(call, payload)
    return unless call.outgoing?
    return if call.terminal?

    started_at = Whatsapp::IncomingCallPayload.timestamp(payload[:timestamp])
    return unless state_sync(call).transition!('in_progress', occurred_at: started_at || Time.current)

    broadcaster.event(call, 'voice_call.outbound_accepted')
  end

  def handle_connect(payload)
    call = call_scope.find_by(provider_call_id: payload[:id])
    if call.nil?
      # Only an `offer` payload is a real inbound caller. An `answer` with no
      # local row means Meta beat our outbound `Call.create!` (tiny window
      # between initiate API response and DB insert) — do not mint an inbound
      # row for it; the next status webhook (or a retry) will find it.
      return create_inbound_call(payload) if inbound_offer?(payload)

      Rails.logger.warn "LLA_WHATSAPP_OUTBOUND_CONNECT_UNKNOWN account=#{inbox.account_id} inbox=#{inbox.id}"
      return
    end

    return accept_outbound_call(call, payload) if call.outgoing?

    Rails.logger.info "LLA_WHATSAPP_INBOUND_CONNECT_DUPLICATE account=#{inbox.account_id} inbox=#{inbox.id}"
  end

  def inbound_offer?(payload)
    payload.dig(:session, :sdp_type).to_s.downcase == 'offer'
  end

  def create_inbound_call(payload)
    unless inbox.channel.inbound_calls_enabled?
      Rails.logger.info "LLA_WHATSAPP_INBOUND_REJECTED account=#{inbox.account_id} inbox=#{inbox.id} reason=disabled"
      inbox.channel.provider_service.reject_call(payload[:id])
      return
    end

    sdp_offer = payload.dig(:session, :sdp)
    Lla::Voice::SdpStore.validate!('offer', sdp_offer)
    call = build_inbound_call(payload, sdp_offer)

    return if call.terminal? # terminated before pickup; no ringing widget to surface

    update_conversation(call)
    broadcaster.incoming(call, sdp_offer)
  end

  # If a terminate already arrived (caller hung up before pickup), finalize it in the
  # SAME transaction as the build so the message's after_create_commit fires (at outer
  # commit) already terminal, never `ringing` — agents aren't rung for a dead call.
  def build_inbound_call(payload, sdp_offer)
    ActiveRecord::Base.transaction do
      identity = Whatsapp::InboundCallIdentityBuilder.new(inbox: inbox, params: params).perform(payload)
      call = Voice::InboundCallBuilder.perform!(inbox: inbox, call_sid: payload[:id],
                                                provider: :whatsapp, caller: identity)
      Lla::Voice::SdpStore.write(call: call, kind: 'offer', sdp: sdp_offer)
      sync_caller_identifiers(call, identity)
      tombstone = consume_terminate_tombstone(payload[:id])
      finalize_terminate(call, tombstone['duration'], tombstone['terminate_reason']) if tombstone
      call
    end
  end

  # Backfill every caller alias (the builder only stores the first) so a later event keyed on any one lands on this thread.
  def sync_caller_identifiers(call, identity)
    Whatsapp::IdentifierSyncService.new(contact_inbox: call.conversation.contact_inbox, contact: call.contact)
                                   .perform(source_ids: identity[:source_ids], phone_number: identity.dig(:contact_attributes, :phone_number))
  end

  # `connect` is the WebRTC tunnel-ready signal, not the pickup signal. Apply
  # Meta's SDP answer so the handshake completes during ringing; the call
  # stays in `ringing` until status=ACCEPTED arrives. Don't gate on
  # in_progress: an out-of-order ACCEPTED can flip status before connect is
  # processed, and dropping the SDP answer would leave the browser without
  # the data it needs to complete the handshake. Use the stored answer as
  # the idempotency key instead.
  def accept_outbound_call(call, payload)
    return if call.terminal?

    sdp_answer = payload.dig(:session, :sdp)&.gsub('a=setup:actpass', 'a=setup:active')
    Lla::Voice::SdpStore.validate!('answer', sdp_answer)
    answer_digest = Lla::Voice::SdpStore.write(call: call, kind: 'answer', sdp: sdp_answer)
    changed = persist_outbound_answer(call, answer_digest)
    broadcaster.event(call, 'voice_call.outbound_connected', sdp_answer: sdp_answer) if changed
  end

  def persist_outbound_answer(call, answer_digest)
    changed = false
    call.with_lock do
      next if call.terminal? || call.meta&.dig('sdp_answer_digest') == answer_digest

      call.update!(meta: (call.meta || {}).merge('sdp_answer_digest' => answer_digest).except('sdp_answer', 'sdp_offer'))
      changed = true
    end
    changed
  end

  def handle_terminate(payload)
    call = call_scope.find_by(provider_call_id: payload[:id])
    if call.nil?
      # Terminate overtook its connect (Meta isn't strictly ordered); tombstone it for the
      # connect handler to consume. An outbound tombstone just expires unused.
      record_terminate_tombstone(payload)
      return
    end

    finalize_terminate(call, payload[:duration], payload[:terminate_reason])
  end

  def finalize_terminate(call, duration, reason)
    duration = Whatsapp::IncomingCallPayload.duration(duration)
    reason = Whatsapp::IncomingCallPayload.reason(reason)
    if call.terminal?
      state_sync(call).reconcile!
      state_sync(call).delete_sdp
      return
    end

    status = derive_terminate_status(call, duration, reason)
    unless state_sync(call).transition!(status, duration_seconds: duration, end_reason: reason)
      call.reload
      state_sync(call).reconcile! if call.terminal?
      return
    end

    state_sync(call).delete_sdp
    broadcaster.event(call, 'voice_call.ended', status: call.display_status, duration_seconds: call.duration_seconds)
  end

  def record_terminate_tombstone(payload)
    tombstone_store.write(payload)
    Rails.logger.info "LLA_WHATSAPP_TERMINATE_TOMBSTONED account=#{inbox.account_id} inbox=#{inbox.id}"
  end

  def consume_terminate_tombstone(provider_call_id)
    tombstone_store.consume(provider_call_id)
  end

  # Provider-reported failures trump the answered/no_answer heuristic. An
  # in_progress call that Meta later terminates with a failure reason would
  # otherwise be recorded as 'completed' purely because it had been accepted.
  FAILURE_REASONS = %w[failed error rejected busy invalid_offer cancelled].freeze

  def derive_terminate_status(call, duration, reason)
    return 'failed' if FAILURE_REASONS.any? { |r| reason.include?(r) }

    answered?(call, duration) ? 'completed' : 'no_answer'
  end

  # accepted_by_agent_id is the initiating agent on outbound calls, so it only signals "answered" for inbound.
  def answered?(call, duration)
    call.in_progress? || duration.to_i.positive? || (call.incoming? && call.accepted_by_agent_id.present?)
  end

  def update_conversation(call)
    call.conversation.update!(
      additional_attributes: (call.conversation.additional_attributes || {}).merge(
        'call_status' => call.display_status, 'call_direction' => call.direction_label
      )
    )
  end

  def call_scope
    Call.where(account_id: inbox.account_id, inbox_id: inbox.id, provider: :whatsapp)
  end

  def tombstone_store
    @tombstone_store ||= Whatsapp::TerminateTombstoneStore.new(inbox: inbox)
  end

  def state_sync(call)
    Whatsapp::IncomingCallStateSync.new(call: call)
  end

  def broadcaster
    @broadcaster ||= Whatsapp::IncomingCallBroadcaster.new(inbox: inbox)
  end
end
