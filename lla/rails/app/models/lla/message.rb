# frozen_string_literal: true

module Lla::Message
  def self.prepended(base)
    base.class_eval do
      scope :with_call, -> { includes(call: :accepted_by_agent) }
    end
  end

  def push_event_data
    super.tap do |data|
      data[:call] = call.push_event_data if content_type == 'voice_call' && call.present?
    end
  end
end
