# frozen_string_literal: true

require 'uri'

class Captain::OpenAiMessageBuilderService
  MAX_TEXT_CHARACTERS = 20_000
  MAX_ATTACHMENTS = 10

  pattr_initialize [:message!]

  def self.extract_text_and_attachments(content)
    return [content, []] unless content.is_a?(Array)

    text_parts = content.filter_map { |part| extract_text_part(part) }
    image_urls = content.filter_map { |part| extract_image_url(part) }
    [text_parts.join(' ').presence, image_urls]
  end

  def self.extract_text_part(part)
    (part[:text] || part['text']) if part_type(part) == 'text'
  end

  def self.extract_image_url(part)
    return unless part_type(part) == 'image_url'

    part.dig(:image_url, :url) || part.dig('image_url', 'url')
  end

  def self.part_type(part)
    part[:type] || part['type']
  end

  private_class_method :extract_text_part, :extract_image_url, :part_type

  def generate_content
    parts = []
    parts << text_part(bounded_text(@message.content)) if @message.content.present?
    parts.concat(attachment_parts(@message.attachments)) if @message.attachments.any?

    return 'Message without content' if parts.blank?
    return parts.first[:text] if parts.one? && parts.first[:type] == 'text'

    parts
  end

  private

  def bounded_text(text)
    text.to_s.truncate(MAX_TEXT_CHARACTERS, omission: '')
  end

  def text_part(text)
    { type: 'text', text: text }
  end

  def image_part(image_url)
    { type: 'image_url', image_url: { url: image_url } }
  end

  def attachment_parts(attachments)
    bounded = attachments.limit(MAX_ATTACHMENTS)
    image_content = image_parts(bounded.where(file_type: :image))
    transcription = extract_audio_transcriptions(bounded)
    transcription_part = text_part(bounded_text(transcription)) if transcription.present?
    generic_part = text_part('User has shared an attachment') if bounded.where.not(file_type: %i[image audio]).exists?

    [image_content, transcription_part, generic_part].flatten.compact
  end

  def image_parts(image_attachments)
    image_attachments.filter_map do |attachment|
      url = safe_attachment_url(attachment)
      image_part(url) if url
    end
  end

  def safe_attachment_url(attachment)
    url = attachment.download_url.presence || attachment.external_url.presence
    url ||= attachment.file_url if attachment.file.attached?
    return if url.blank?

    uri = URI.parse(url)
    raise Lla::Network::UrlSafety::UnsafeUrlError, 'image URL must use HTTPS' unless uri.scheme == 'https'

    Lla::Network::UrlSafety.validate!(url)
    url
  rescue URI::InvalidURIError, Lla::Network::UrlSafety::UnsafeUrlError => e
    Rails.logger.warn("LLA image URL rejected attachment_id=#{attachment.id} error=#{e.class.name}")
    nil
  end

  # Kept as the compatibility seam used by existing Captain callers and specs.
  # Validation remains centralized so legacy callers cannot bypass URL safety.
  def get_attachment_url(attachment)
    safe_attachment_url(attachment)
  end

  def extract_audio_transcriptions(attachments)
    attachments.where(file_type: :audio).filter_map do |attachment|
      result = Messages::AudioTranscriptionService.new(attachment).perform
      result[:transcriptions].to_s.strip if result[:success]
    end.join(' ')
  end
end
