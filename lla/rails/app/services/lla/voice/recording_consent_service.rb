# frozen_string_literal: true

class Lla::Voice::RecordingConsentService
  class InvalidAttestation < StandardError; end

  ATTESTATION_PATTERN = /\A[A-Za-z0-9_.:-]{8,128}\z/
  MAX_CLOCK_SKEW = 10.minutes

  def initialize(account:, inbox:, user:, call:, attestation:)
    @account = account
    @inbox = inbox
    @user = user
    @call = call
    @attestation = normalize(attestation)
  end

  def capture
    return unless recording_policy_enabled?

    validate_context!
    validate_attestation!
    existing = existing_attestation
    return validate_existing!(existing) if existing

    create_evidence!
  rescue InvalidAttestation => e
    log_rejection(e.message)
    nil
  rescue ActiveRecord::ActiveRecordError => e
    log_rejection(e.class.name)
    nil
  end

  def self.payload_digest(attestation)
    payload = normalize_payload(attestation)
    Digest::SHA256.hexdigest(payload.slice(*canonical_keys).sort.to_h.to_json)
  end

  def self.capture_and_attach!(call:, user:, attestation:)
    consent = new(account: call.account, inbox: call.inbox, user: user, call: call, attestation: attestation).capture
    call.update!(meta: call.meta.merge('recording_consent_id' => consent.id)) if consent
    consent
  end

  def self.normalize_payload(attestation)
    value = attestation.respond_to?(:to_unsafe_h) ? attestation.to_unsafe_h : attestation
    value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
  end

  def self.canonical_keys
    %w[accepted attestation_id attested_at disclosure_version method]
  end

  private

  attr_reader :account, :inbox, :user, :call, :attestation

  def normalize(value)
    self.class.normalize_payload(value)
  end

  def recording_policy_enabled?
    ActiveModel::Type::Boolean.new.cast(config['voice_recording_enabled'])
  end

  def validate_context!
    valid = call.account_id == account.id && call.inbox_id == inbox.id && inbox.account_id == account.id
    raise InvalidAttestation, 'context_mismatch' unless valid
    raise InvalidAttestation, 'membership_missing' unless account.account_users.exists?(user_id: user.id)
  end

  def validate_attestation!
    raise InvalidAttestation, 'not_accepted' unless ActiveModel::Type::Boolean.new.cast(attestation['accepted'])
    raise InvalidAttestation, 'invalid_method' unless attestation['method'] == 'agent_attestation'
    raise InvalidAttestation, 'invalid_id' unless ATTESTATION_PATTERN.match?(attestation['attestation_id'].to_s)
    raise InvalidAttestation, 'stale_disclosure' unless attestation['disclosure_version'] == disclosure_version
    raise InvalidAttestation, 'invalid_timestamp' unless client_attested_at
    raise InvalidAttestation, 'stale_timestamp' if (Time.current - client_attested_at).abs > MAX_CLOCK_SKEW
  end

  def existing_attestation
    Lla::Voice::RecordingConsent.find_by(account_id: account.id, attestation_digest: attestation_digest)
  end

  def validate_existing!(existing)
    raise InvalidAttestation, 'attestation_replayed' unless existing.call_id == call.id && existing.inbox_id == inbox.id

    existing
  end

  def create_evidence!
    captured_at = Time.current
    attributes = {
      account: account,
      inbox: inbox,
      call: call,
      user: user,
      capture_method: 'agent_attestation',
      disclosure_version: disclosure_version,
      attestation_digest: attestation_digest,
      actor_reference_digest: digest("#{account.id}:#{user.id}"),
      client_attested_at: client_attested_at,
      captured_at: captured_at
    }
    attributes[:evidence_digest] = evidence_digest(attributes)
    ActiveRecord::Base.transaction(requires_new: true) do
      Lla::Voice::RecordingConsent.create!(attributes)
    end
  rescue ActiveRecord::RecordNotUnique
    validate_existing!(existing_attestation || raise(InvalidAttestation, 'attestation_conflict'))
  end

  def evidence_digest(attributes)
    digest([
      account.id, inbox.id, call.id, attributes[:actor_reference_digest], attributes[:capture_method],
      attributes[:disclosure_version], attributes[:attestation_digest], client_attested_at.iso8601(6),
      attributes[:captured_at].iso8601(6)
    ].join(':'))
  end

  def attestation_digest
    @attestation_digest ||= digest(attestation['attestation_id'])
  end

  def disclosure_version
    @disclosure_version ||= config['voice_recording_disclosure_version'].to_s
  end

  def client_attested_at
    @client_attested_at ||= Time.iso8601(attestation['attested_at'].to_s)
  rescue ArgumentError
    nil
  end

  def config
    @config ||= (inbox.channel.provider_config || {}).to_h
  end

  def log_rejection(code)
    Rails.logger.warn(
      "LLA_VOICE_RECORDING_CONSENT_REJECTED account=#{account.id} inbox=#{inbox.id} " \
      "call=#{call.id} code=#{code.to_s.gsub(/[^A-Za-z0-9_:]/, '').first(80)}"
    )
  end

  def digest(value) = Digest::SHA256.hexdigest(value.to_s)
end
