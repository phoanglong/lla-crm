# frozen_string_literal: true

# Thin, fail-closed HTTP client for the Cloudflare custom hostname API.
#
# The base URI is a constant (no operator supplied endpoint), redirects are never
# followed, every call is bounded by a timeout, and no response body is ever
# logged or attached to an error: callers only ever see a typed error code.
class Lla::CustomDomains::Providers::CloudflareClient
  BASE_URI = 'https://api.cloudflare.com/client/v4'
  TIMEOUT = 8
  TOKEN_REFERENCE_ENV = 'LLA_CLOUDFLARE_API_TOKEN_REF'
  ZONE_REFERENCE_ENV = 'LLA_CLOUDFLARE_ZONE_ID_REF'
  ZONE_PATTERN = /\A[a-f0-9]{32}\z/
  RESOURCE_ID_PATTERN = /\A[A-Za-z0-9_-]{1,128}\z/

  def self.configured?
    credentials.present?
  end

  def self.list_custom_hostnames(hostname)
    request(:get, "/zones/#{zone_id!}/custom_hostnames", query: { hostname: hostname })
  end

  def self.create_custom_hostname(hostname)
    request(:post, "/zones/#{zone_id!}/custom_hostnames",
            body: { hostname: hostname, ssl: { method: 'http', type: 'dv' } }.to_json)
  end

  def self.delete_custom_hostname(resource_id)
    raise Lla::CustomDomains::ProviderErrors::ClientError unless RESOURCE_ID_PATTERN.match?(resource_id.to_s)

    request(:delete, "/zones/#{zone_id!}/custom_hostnames/#{resource_id}")
  end

  def self.credentials
    token = Lla::Security::SecretReference.resolve_from_env(TOKEN_REFERENCE_ENV)
    zone = Lla::Security::SecretReference.resolve_from_env(ZONE_REFERENCE_ENV)
    return if token.blank? || !ZONE_PATTERN.match?(zone.to_s)

    { token: token, zone_id: zone }
  end

  def self.zone_id!
    credentials&.fetch(:zone_id) || raise(Lla::CustomDomains::ProviderErrors::NotConfigured)
  end
  private_class_method :zone_id!

  def self.request(verb, path, query: nil, body: nil)
    credential = credentials
    raise Lla::CustomDomains::ProviderErrors::NotConfigured if credential.blank?

    response = HTTParty.public_send(
      verb, "#{BASE_URI}#{path}",
      headers: headers(credential[:token]), query: query, body: body,
      timeout: TIMEOUT, follow_redirects: false
    )
    interpret(response)
  rescue Timeout::Error, Errno::ETIMEDOUT
    raise Lla::CustomDomains::ProviderErrors::Timeout
  rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError, HTTParty::Error
    raise Lla::CustomDomains::ProviderErrors::ServerError
  end
  private_class_method :request

  def self.headers(token)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
  end
  private_class_method :headers

  def self.interpret(response)
    status = response.code.to_i
    return parse_result(response) if status.between?(200, 299)
    raise Lla::CustomDomains::ProviderErrors::NotFound if status == 404
    raise Lla::CustomDomains::ProviderErrors::Unauthorized if [401, 403].include?(status)
    raise Lla::CustomDomains::ProviderErrors::Timeout if [408, 429].include?(status)
    raise Lla::CustomDomains::ProviderErrors::ServerError if status >= 500

    raise Lla::CustomDomains::ProviderErrors::ClientError
  end
  private_class_method :interpret

  def self.parse_result(response)
    payload = response.parsed_response
    raise Lla::CustomDomains::ProviderErrors::ServerError unless payload.is_a?(Hash)

    payload['result']
  end
  private_class_method :parse_result
end
