# frozen_string_literal: true

# Chặn SSRF cho endpoint do người dùng cấu hình: chỉ nhận http/https tới host
# công cộng — từ chối loopback/địa chỉ nội bộ. Biến liquid trong URL được thay
# tạm bằng placeholder trước khi parse.
module Concerns::SafeEndpointValidatable
  extend ActiveSupport::Concern

  included do
    validate :validate_endpoint_url_safety
  end

  private

  def validate_endpoint_url_safety
    return if endpoint_url.blank?

    uri = parse_endpoint_uri
    return errors.add(:endpoint_url, 'must be a valid http(s) URL') if uri.nil? || !uri.is_a?(URI::HTTP) || uri.host.blank?

    errors.add(:endpoint_url, 'cannot point to a local or private address') if unsafe_endpoint_host?(uri.host)
  end

  def parse_endpoint_uri
    URI.parse(endpoint_url.gsub(/{{.*?}}/, 'template-var'))
  rescue URI::InvalidURIError
    nil
  end

  def unsafe_endpoint_host?(host)
    normalized = host.downcase
    return true if normalized == 'localhost' || normalized.end_with?('.localhost', '.local', '.internal')

    unsafe_ip?(normalized)
  end

  def unsafe_ip?(host)
    ip = IPAddr.new(host)
    ip.loopback? || ip.private? || ip.link_local? || ip.to_s == '0.0.0.0'
  rescue IPAddr::InvalidAddressError
    false
  end
end
