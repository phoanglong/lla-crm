# frozen_string_literal: true

# Zalo bắt chứng minh quyền sở hữu tên miền bằng một bản ghi TXT trước khi cho phép
# đặt Webhook/Callback thuộc tên miền đó. Người vận hành dán bản ghi ở nhà cung cấp
# DNS của họ rồi ngồi đoán "đã lan chưa" — dịch vụ này trả lời bằng cách tra thật.
class Lla::Zalo::DomainVerification
  PREFIX = 'zalo-platform-site-verification='
  DOMAIN_PATTERN = /\A(?=.{1,253}\z)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/
  TIMEOUT = 5

  class InvalidDomain < StandardError; end

  # `expected` là mã Zalo hiện trong màn hình Developers. Không truyền thì chỉ trả
  # lời "có bản ghi xác minh Zalo nào không".
  def self.check(domain, expected: nil)
    normalized = domain.to_s.strip.downcase.sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '')
    raise InvalidDomain unless DOMAIN_PATTERN.match?(normalized)

    codes = verification_codes(normalized)
    {
      domain: normalized,
      codes: codes,
      found: codes.any?,
      matches: expected.present? ? codes.include?(expected.to_s.strip) : nil
    }
  end

  def self.verification_codes(domain)
    Resolv::DNS.open do |dns|
      dns.timeouts = TIMEOUT
      dns.getresources(domain, Resolv::DNS::Resource::IN::TXT)
         .flat_map(&:strings)
         .select { |value| value.to_s.start_with?(PREFIX) }
         .map { |value| value.to_s.delete_prefix(PREFIX) }
    end
  rescue Resolv::ResolvError, Resolv::ResolvTimeout, IOError
    []
  end
  private_class_method :verification_codes
end
