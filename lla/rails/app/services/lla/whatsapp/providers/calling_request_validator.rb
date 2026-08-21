# frozen_string_literal: true

class Lla::Whatsapp::Providers::CallingRequestValidator
  class << self
    def validate_base!(base)
      uri = URI.parse(base)
      raise ArgumentError, 'Invalid WhatsApp API base URL' unless valid_base?(uri)
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid WhatsApp API base URL'
    end

    def validate_api_version!(value)
      raise ArgumentError, 'Invalid WhatsApp API version' unless value.to_s.match?(/\Av\d+\.\d+\z/)
    end

    def validate_phone_number_id!(value)
      raise ArgumentError, 'Invalid WhatsApp phone number ID' unless value.to_s.match?(/\A\d{4,32}\z/)
    end

    def validate_destination!(value)
      raise ArgumentError, 'Invalid WhatsApp destination' unless value.to_s.match?(/\A[1-9]\d{6,14}\z/)
    end

    def validate_call_id!(value)
      raise ArgumentError, 'Invalid WhatsApp call identifier' unless value.to_s.match?(/\A[A-Za-z0-9_.:-]{4,255}\z/)
    end

    private

    def valid_base?(uri)
      uri.is_a?(URI::HTTPS) && uri.userinfo.blank? && allowed_hosts.include?(uri.host) &&
        uri.path.to_s.delete('/').blank? && uri.query.blank? && uri.fragment.blank?
    end

    def allowed_hosts
      ['graph.facebook.com', *ENV.fetch('LLA_META_ALLOWED_HOSTS', '').split(',').map(&:strip)].compact_blank
    end
  end
end
