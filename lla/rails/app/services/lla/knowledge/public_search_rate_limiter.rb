# frozen_string_literal: true

class Lla::Knowledge::PublicSearchRateLimiter
  LIMIT = 30
  WINDOW = 1.minute

  def self.allowed?(portal:, requester_key:)
    digest = Digest::SHA256.hexdigest([portal.account_id, portal.id, requester_key.to_s].join("\0"))
    count = Rails.cache.increment("lla:knowledge:semantic-search:#{digest}", 1, expires_in: WINDOW, initial: 0)
    count.present? && count <= LIMIT
  rescue StandardError => e
    Rails.logger.warn("LLA semantic search rate limiter unavailable portal_id=#{portal.id} error=#{e.class.name}")
    false
  end
end
