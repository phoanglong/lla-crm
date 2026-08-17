# frozen_string_literal: true

# Central fail-closed gate for every external provider used by LLA Knowledge.
# Secrets are deliberately not read here: adapters receive secret references
# only after this policy grants a specific capability for a specific account.
class Lla::Knowledge::ProviderPolicy
  class Denied < StandardError
    attr_reader :code

    def initialize(code = 'lla_knowledge_provider_disabled')
      @code = code
      super(code)
    end
  end

  CAPABILITY_FLAGS = {
    website_analysis: 'LLA_KNOWLEDGE_WEBSITE_ANALYSIS_ENABLED',
    external_crawl: 'LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED',
    article_generation: 'LLA_KNOWLEDGE_ARTICLE_GENERATION_ENABLED',
    article_translation: 'LLA_KNOWLEDGE_ARTICLE_TRANSLATION_ENABLED',
    embedding_search: 'LLA_KNOWLEDGE_EMBEDDING_SEARCH_ENABLED',
    website_enrichment: 'LLA_KNOWLEDGE_WEBSITE_ENRICHMENT_ENABLED',
    custom_domains: 'LLA_CUSTOM_DOMAINS_ENABLED',
    geo_restrictions: 'LLA_WIDGET_GEO_RESTRICTIONS_ENABLED'
  }.freeze

  PROVIDERS = %i[direct_fetch openai firecrawl context_dev cloudflare geoip].freeze
  CONSENT_ROOT = 'lla_provider_consents'
  GLOBAL_EGRESS_FLAG = 'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED'
  CONSENT_VERSION_PATTERN = /\A[a-zA-Z0-9_.-]{1,40}\z/

  def self.capability_enabled?(capability)
    flag = CAPABILITY_FLAGS.fetch(capability.to_sym)
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(flag, false))
  end

  def self.egress_permitted?(account:, provider:, capability:)
    validate_provider!(provider)
    global_egress_enabled? && capability_enabled?(capability) && consented?(account, provider)
  end

  def self.authorize_egress!(account:, provider:, capability:)
    return true if egress_permitted?(account: account, provider: provider, capability: capability)

    raise Denied
  end

  def self.consented?(account, provider)
    record = consent_record(account, provider)
    return false unless ActiveModel::Type::Boolean.new.cast(record['enabled'])
    return false unless CONSENT_VERSION_PATTERN.match?(record['version'].to_s)

    accepted_at = Time.zone.parse(record['accepted_at'].to_s)
    accepted_at.present? && accepted_at <= 5.minutes.from_now
  rescue ArgumentError
    false
  end

  def self.consent_digest(account, provider)
    return unless consented?(account, provider)

    record = consent_record(account, provider)
    Digest::SHA256.hexdigest([account.id, provider, record['version'], record['accepted_at']].join("\0"))
  end

  def self.global_egress_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(GLOBAL_EGRESS_FLAG, false))
  end

  def self.validate_provider!(provider)
    return if provider.to_sym.in?(PROVIDERS)

    raise ArgumentError, "unknown LLA Knowledge provider: #{provider}"
  end
  private_class_method :validate_provider!

  def self.consent_record(account, provider)
    value = account&.custom_attributes&.dig(CONSENT_ROOT, provider.to_s)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end
  private_class_method :consent_record
end
