class IpLookupService
  def perform(ip_address)
    return if ip_address.blank? || !ip_database_available?

    Geocoder.search(ip_address).first
  rescue Errno::ETIMEDOUT => e
    # `Logger#warn` returns true, so returning its value here handed every caller a
    # `true` that is not a lookup result. Callers then send `country_code` to it and
    # get a NoMethodError on whatever request triggered the timeout.
    Rails.logger.warn "Exception: IP resolution failed :#{e.message}"
    nil
  end

  private

  def ip_database_available?
    File.exist?(GeocoderConfiguration::LOOK_UP_DB)
  end
end
