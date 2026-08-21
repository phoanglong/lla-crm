# frozen_string_literal: true

require 'addressable/idna'
require 'resolv'

# Single canonical form for every customer supplied hostname. Everything that is
# not a bare, DNS-safe, single-script host is rejected with a stable error code:
# no scheme, port, path, query, userinfo, CRLF, whitespace, IP literal, reserved
# suffix or mixed-script (confusable) label ever reaches the database.
class Lla::CustomDomains::HostCanonicalizer
  class InvalidHost < StandardError
    attr_reader :code

    def initialize(code = 'lla_custom_domain_invalid_host')
      @code = code
      super(code)
    end
  end

  MIN_LENGTH = 4
  MAX_LENGTH = 253
  MAX_LABEL_LENGTH = 63
  ASCII_HOST = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/
  CONTROL_OR_SPACE = /[\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200f\u2028-\u202f\u205f-\u2060\u3000\ufeff\ufff9-\ufffb]/
  RESERVED_SUFFIXES = %w[localhost local internal localdomain intranet home lan corp test example invalid onion].freeze
  SCHEME_PREFIX = %r{\Ahttps?://}i
  TLD_PATTERN = /\A(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})\z/
  SCRIPT_PATTERNS = {
    latin: /\p{Latin}/, cyrillic: /\p{Cyrillic}/, greek: /\p{Greek}/, han: /\p{Han}/,
    hiragana: /\p{Hiragana}/, katakana: /\p{Katakana}/, hangul: /\p{Hangul}/,
    arabic: /\p{Arabic}/, hebrew: /\p{Hebrew}/, thai: /\p{Thai}/, devanagari: /\p{Devanagari}/
  }.freeze

  def self.call(value)
    raw = coerce_utf8(value)
    raise InvalidHost, 'lla_custom_domain_blank_host' if raw.strip.empty?
    raise InvalidHost, 'lla_custom_domain_control_character' if CONTROL_OR_SPACE.match?(raw)

    unicode_host = normalize(raw)
    reject_non_host_syntax!(unicode_host)
    reject_confusable_labels!(unicode_host)
    validate_ascii!(to_ascii(unicode_host))
  end

  # Write boundary for operator input. Administrators habitually paste the portal
  # URL, so exactly one leading scheme and one trailing slash are tolerated before
  # the strict rules apply; a real path, port, query or userinfo is still rejected.
  def self.from_user_input(value)
    raw = coerce_utf8(value).strip
    raw = raw.sub(SCHEME_PREFIX, '').delete_suffix('/') if SCHEME_PREFIX.match?(raw)
    call(raw)
  end

  # Nil-returning variant for read paths (host lookup) where an unusable Host
  # header is an ordinary miss rather than an error.
  def self.canonicalize(value)
    call(value)
  rescue InvalidHost
    nil
  end

  # `Addressable::IDNA` hands back ASCII-8BIT strings; normalising or comparing
  # those against UTF-8 input raises instead of answering, so every entry point
  # coerces to UTF-8 first and rejects anything that is not valid text.
  def self.coerce_utf8(value)
    raw = value.to_s
    raw = raw.dup.force_encoding(Encoding::UTF_8) if raw.encoding != Encoding::UTF_8 && raw.ascii_only?
    raise InvalidHost, 'lla_custom_domain_invalid_encoding' unless raw.encoding == Encoding::UTF_8 && raw.valid_encoding?

    raw
  end
  private_class_method :coerce_utf8

  def self.normalize(raw)
    raw.unicode_normalize(:nfkc).downcase.delete_suffix('.')
  rescue ArgumentError, Encoding::CompatibilityError
    raise InvalidHost, 'lla_custom_domain_invalid_encoding'
  end
  private_class_method :normalize

  def self.reject_non_host_syntax!(host)
    raise InvalidHost, 'lla_custom_domain_blank_host' if host.empty?
    raise InvalidHost, 'lla_custom_domain_control_character' if CONTROL_OR_SPACE.match?(host)
    raise InvalidHost, 'lla_custom_domain_userinfo_not_allowed' if host.include?('@')
    raise InvalidHost, 'lla_custom_domain_scheme_or_port_not_allowed' if host.include?(':')
    raise InvalidHost, 'lla_custom_domain_path_not_allowed' if host.match?(%r{[/\\?#]})

    reject_dot_syntax!(host)
  end
  private_class_method :reject_non_host_syntax!

  def self.reject_dot_syntax!(host)
    return unless host.include?('..') || host.start_with?('.') || host.end_with?('.')

    raise InvalidHost, 'lla_custom_domain_invalid_label'
  end
  private_class_method :reject_dot_syntax!

  # A single label mixing scripts is the classic homograph vector ("аpple.com").
  # Whole-label single-script IDNs stay usable.
  def self.reject_confusable_labels!(host)
    decoded = begin
      Addressable::IDNA.to_unicode(host)
    rescue StandardError
      host
    end

    decoded.split('.').each do |label|
      scripts = SCRIPT_PATTERNS.count { |_name, pattern| pattern.match?(label) }
      raise InvalidHost, 'lla_custom_domain_confusable_host' if scripts > 1
    end
  end
  private_class_method :reject_confusable_labels!

  def self.to_ascii(host)
    ascii = coerce_utf8(Addressable::IDNA.to_ascii(host))
    raise InvalidHost, 'lla_custom_domain_invalid_idna' if ascii.empty?

    ascii
  rescue InvalidHost
    raise
  rescue StandardError
    raise InvalidHost, 'lla_custom_domain_invalid_idna'
  end
  private_class_method :to_ascii

  def self.validate_ascii!(host)
    validate_length!(host)
    raise InvalidHost, 'lla_custom_domain_invalid_label' unless ASCII_HOST.match?(host)
    raise InvalidHost, 'lla_custom_domain_ip_literal_not_allowed' if ip_literal?(host)

    validate_labels!(host.split('.'))
    host
  end
  private_class_method :validate_ascii!

  def self.validate_length!(host)
    raise InvalidHost, 'lla_custom_domain_host_too_long' if host.bytesize > MAX_LENGTH
    raise InvalidHost, 'lla_custom_domain_host_too_short' if host.bytesize < MIN_LENGTH
  end
  private_class_method :validate_length!

  def self.validate_labels!(labels)
    raise InvalidHost, 'lla_custom_domain_invalid_label' if labels.any? { |label| label.bytesize > MAX_LABEL_LENGTH }
    raise InvalidHost, 'lla_custom_domain_invalid_tld' unless TLD_PATTERN.match?(labels.last)
    raise InvalidHost, 'lla_custom_domain_reserved_suffix' if RESERVED_SUFFIXES.include?(labels.last)
  end
  private_class_method :validate_labels!

  def self.ip_literal?(host)
    Resolv::IPv4::Regex.match?(host) || Resolv::IPv6::Regex.match?(host)
  end
  private_class_method :ip_literal?
end
