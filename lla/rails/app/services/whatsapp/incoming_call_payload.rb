# frozen_string_literal: true

class Whatsapp::IncomingCallPayload
  MAX_EVENTS = 100

  class << self
    def entries(value)
      values = Array(value)
      raise ArgumentError, 'Too many WhatsApp call events' if values.size > MAX_EVENTS

      values
    end

    def validate_call_id!(value)
      Lla::Whatsapp::Providers::CallingRequestValidator.validate_call_id!(value)
    end

    def timestamp(value)
      timestamp = Integer(value, exception: false)
      return if timestamp.blank?

      candidate = Time.zone.at(timestamp)
      candidate if candidate.between?(7.days.ago, 5.minutes.from_now)
    rescue RangeError
      nil
    end

    def duration(value)
      duration = Integer(value, exception: false)
      duration if duration&.between?(0, 24.hours.to_i)
    end

    def reason(value)
      value.to_s.gsub(/[^0-9A-Za-z_.:-]/, '').first(80)
    end
  end
end
