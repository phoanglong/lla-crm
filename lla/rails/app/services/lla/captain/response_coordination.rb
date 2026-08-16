# frozen_string_literal: true

require 'securerandom'

# Coordinates Captain response scheduling across web processes and workers.
# Tokens include the triggering message for diagnostics but are never used as
# authorization; Redis compare-and-delete protects ownership during release.
class Lla::Captain::ResponseCoordination
  SCHEDULE_TTL = 10.minutes.to_i
  EXECUTION_TTL = 5.minutes.to_i
  SCHEDULE_KEY = 'LLA_CAPTAIN_RESPONSE_SCHEDULE::%<account_id>d::%<conversation_id>d'
  EXECUTION_KEY = 'LLA_CAPTAIN_RESPONSE_EXECUTION::%<account_id>d::%<conversation_id>d'

  class << self
    def schedule_key(account_id:, conversation_id:)
      format(SCHEDULE_KEY, account_id: account_id, conversation_id: conversation_id)
    end

    def execution_key(account_id:, conversation_id:)
      format(EXECUTION_KEY, account_id: account_id, conversation_id: conversation_id)
    end

    def scheduling_token(message_id)
      "#{message_id}:#{SecureRandom.hex(16)}"
    end

    def scheduled_message_id(token)
      Integer(token.to_s.split(':', 2).first, 10)
    rescue ArgumentError
      nil
    end
  end
end
