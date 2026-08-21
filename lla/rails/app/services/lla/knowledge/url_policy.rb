# frozen_string_literal: true

class Lla::Knowledge::UrlPolicy
  class InvalidUrl < StandardError; end

  HOST_PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  def self.canonicalize(value)
    canonicalize_uri(parse_uri(value)).to_s
  rescue URI::InvalidURIError => e
    raise InvalidUrl, e.message
  end

  def self.approved_same_origin?(origin, candidate)
    canonical_origin = canonicalize(origin)
    canonical_candidate = canonicalize(candidate)
    Lla::Network::UrlSafety.same_origin?(canonical_origin, canonical_candidate)
  rescue InvalidUrl
    false
  end

  def self.canonical_source(value)
    uri = URI.parse(canonicalize(value))
    uri.query = nil
    uri.to_s
  rescue URI::InvalidURIError => e
    raise InvalidUrl, e.message
  end

  def self.default_port?(uri)
    uri.port == uri.default_port
  end
  private_class_method :default_port?

  def self.parse_uri(value)
    URI.parse(value.to_s.strip).tap do |uri|
      raise InvalidUrl, 'only absolute HTTP(S) URLs are allowed' unless uri.is_a?(URI::HTTP) && uri.host.present?
      raise InvalidUrl, 'URL credentials are not allowed' if uri.userinfo.present?
      raise InvalidUrl, 'non-default ports are not allowed' unless default_port?(uri)
    end
  end
  private_class_method :parse_uri

  def self.canonicalize_uri(uri)
    host = uri.host.downcase.delete_suffix('.')
    raise InvalidUrl, 'host must use canonical ASCII DNS labels' unless HOST_PATTERN.match?(host)

    uri.host = host
    uri.fragment = nil
    uri.path = '/' if uri.path.blank?
    uri
  end
  private_class_method :canonicalize_uri
end
