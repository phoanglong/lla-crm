# frozen_string_literal: true

require 'ipaddr'
require 'resolv'
require 'uri'

# Runtime SSRF guard for URLs fetched by LLA-owned HTTP clients.
# It validates every redirect target and returns a resolved public IP so the
# caller can pin the connection and avoid a second, attacker-controlled lookup.
class Lla::Network::UrlSafety
  class UnsafeUrlError < StandardError; end

  BLOCKED_NETWORKS = [
    IPAddr.new('0.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('100.64.0.0/10'),
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.0.0.0/24'),
    IPAddr.new('192.0.2.0/24'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('198.18.0.0/15'),
    IPAddr.new('198.51.100.0/24'),
    IPAddr.new('203.0.113.0/24'),
    IPAddr.new('224.0.0.0/4'),
    IPAddr.new('240.0.0.0/4'),
    IPAddr.new('::/128'),
    IPAddr.new('::1/128'),
    IPAddr.new('::ffff:0:0/96'),
    IPAddr.new('100::/64'),
    IPAddr.new('2001:db8::/32'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10'),
    IPAddr.new('ff00::/8')
  ].freeze

  Result = Struct.new(:uri, :ip_address, keyword_init: true)

  def self.validate!(url)
    uri = URI.parse(url.to_s)
    validate_uri!(uri)
    ips = resolve_public_ips!(normalized_host(uri))

    Result.new(uri: uri, ip_address: ips.first.to_s)
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError => e
    raise UnsafeUrlError, "invalid URL: #{e.message}"
  end

  def self.same_origin?(left, right)
    left_uri = left.is_a?(URI) ? left : URI.parse(left.to_s)
    right_uri = right.is_a?(URI) ? right : URI.parse(right.to_s)
    [left_uri.scheme, left_uri.host&.downcase, left_uri.port] == [right_uri.scheme, right_uri.host&.downcase, right_uri.port]
  rescue URI::InvalidURIError
    false
  end

  def self.local_hostname?(host)
    host == 'localhost' || host.end_with?('.localhost', '.local', '.internal')
  end
  private_class_method :local_hostname?

  def self.validate_uri!(uri)
    raise UnsafeUrlError, 'only absolute http(s) URLs are allowed' unless uri.is_a?(URI::HTTP) && uri.host.present?
    raise UnsafeUrlError, 'URL credentials are not allowed' if uri.userinfo.present?
  end
  private_class_method :validate_uri!

  def self.normalized_host(uri)
    host = uri.host.downcase.delete_suffix('.')
    raise UnsafeUrlError, 'local hostnames are not allowed' if local_hostname?(host)

    host
  end
  private_class_method :normalized_host

  def self.resolve_public_ips!(host)
    addresses = Resolv.getaddresses(host)
    raise UnsafeUrlError, 'host did not resolve' if addresses.empty?

    addresses.map { |address| IPAddr.new(address) }.tap do |ips|
      raise UnsafeUrlError, 'host resolves to a non-public address' if ips.any? { |ip| blocked_ip?(ip) }
    end
  end
  private_class_method :resolve_public_ips!

  def self.blocked_ip?(ip)
    BLOCKED_NETWORKS.any? { |network| network.include?(ip) }
  end
  private_class_method :blocked_ip?
end
