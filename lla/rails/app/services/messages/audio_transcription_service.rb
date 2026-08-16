# frozen_string_literal: true

require 'tempfile'
require 'uri'

class Messages::AudioTranscriptionService
  class QuotaExceededError < StandardError; end

  TRANSCRIPTION_BYTE_LIMIT = 25_000_000
  DEFAULT_API_ENDPOINT = 'https://api.openai.com/'

  attr_reader :attachment, :message, :account, :transcription_model

  def initialize(attachment)
    @attachment = attachment
    @message = attachment.message
    @account = @message&.account
    @transcription_model = account && Llm::FeatureRouter.resolve(feature: 'audio_transcription', account: account)[:model]
  end

  def perform
    return { error: 'Invalid audio attachment context' } unless valid_context?

    return successful_response(cached_transcription) if cached_transcription

    error = transcription_preflight_error
    return { error: error } if error

    transcriptions = transcribe_audio
    Rails.logger.info(
      "LLA audio transcription completed account_id=#{account.id} message_id=#{message.id} " \
      "attachment_id=#{attachment.id} model=#{transcription_model}"
    )
    successful_response(transcriptions)
  rescue QuotaExceededError
    { error: 'Transcription limit exceeded' }
  rescue Faraday::UnauthorizedError => e
    Rails.logger.warn("LLA audio transcription unauthorized account_id=#{account&.id} error=#{e.class.name}")
    { error: 'Audio transcription provider unauthorized' }
  end

  private

  def valid_context?
    message.present? && account.present? && attachment.account_id == message.account_id && message.account_id == account.id && attachment.audio?
  end

  def cached_transcription
    attachment.meta&.dig('transcribed_text').presence
  end

  def successful_response(transcriptions)
    { success: true, transcriptions: transcriptions }
  end

  def transcription_preflight_error
    return 'Transcription limit exceeded' unless can_transcribe?
    return 'Audio too large for Whisper' if attachment.file.attached? && audio_too_large?
  end

  def can_transcribe?
    account.feature_enabled?('captain_integration') &&
      ActiveModel::Type::Boolean.new.cast(account.audio_transcriptions) &&
      account.usage_limits.dig(:captain, :responses, :current_available).to_i.positive? &&
      api_key.present?
  end

  def audio_too_large?
    attachment.file.blob.byte_size > TRANSCRIPTION_BYTE_LIMIT
  end

  def fetch_audio_file
    blob = attachment.file.blob
    tempfile = audio_tempfile(blob)

    blob.open { |blob_file| IO.copy_stream(blob_file, tempfile) }
    tempfile.close
    tempfile.path
  rescue StandardError
    tempfile&.close!
    raise
  end

  def audio_tempfile(blob)
    temp_dir = Rails.root.join('tmp/uploads/audio-transcriptions')
    FileUtils.mkdir_p(temp_dir)
    Tempfile.new(['lla-audio-', safe_extension(blob)], temp_dir).tap(&:binmode)
  end

  def transcribe_audio
    temp_file_path = fetch_audio_file
    response = nil

    ActiveSupport::Notifications.instrument(
      'lla.captain.audio_transcription',
      account_id: account.id,
      message_id: message.id,
      attachment_id: attachment.id,
      model: transcription_model
    ) do
      File.open(temp_file_path, 'rb') do |file|
        response = client.audio.transcribe(
          parameters: { model: transcription_model, file: file, temperature: 0.0 }
        )
      end
    end

    transcribed_text = response['text'].to_s
    update_transcription(transcribed_text).presence || transcribed_text
  ensure
    FileUtils.rm_f(temp_file_path) if temp_file_path.present?
  end

  def persist_transcription(transcribed_text)
    return '' if transcribed_text.blank?

    persisted_text = attachment.with_lock { persist_transcription_with_quota!(transcribed_text) }

    message.reload.send_update_event
    message.reindex if ChatwootApp.advanced_search_allowed?
    persisted_text
  end

  def persist_transcription_with_quota!(transcribed_text)
    existing = attachment.meta&.dig('transcribed_text').presence
    return existing if existing

    raise QuotaExceededError unless account.increment_response_usage

    attachment.update!(meta: (attachment.meta || {}).merge('transcribed_text' => transcribed_text))
    transcribed_text
  end

  def update_transcription(transcribed_text)
    persist_transcription(transcribed_text)
  end

  def client
    @client ||= OpenAI::Client.new(
      access_token: api_key,
      uri_base: api_endpoint,
      log_errors: false
    )
  end

  def api_key
    @api_key ||= begin
      hook_key = account.hooks.find_by(app_id: 'openai', status: 'enabled')&.settings&.dig('api_key').presence
      hook_key || InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value.presence
    end
  end

  def api_endpoint
    endpoint = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence || DEFAULT_API_ENDPOINT
    uri = URI.parse(endpoint)
    raise ArgumentError, 'Audio transcription endpoint must use HTTPS' unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank?

    endpoint
  rescue URI::InvalidURIError => e
    raise ArgumentError, "Invalid audio transcription endpoint: #{e.class.name}"
  end

  def safe_extension(blob)
    extension = blob.filename.extension_without_delimiter.to_s.downcase
    extension = extension_from_content_type(blob.content_type) if extension.blank?
    extension = extension.gsub(/[^a-z0-9]/, '')
    extension.present? ? ".#{extension.first(10)}" : '.audio'
  end

  def extension_from_content_type(content_type)
    subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
    { 'x-m4a' => 'm4a', 'x-wav' => 'wav', 'x-mp3' => 'mp3' }.fetch(subtype, subtype)
  end

  public :client
end
