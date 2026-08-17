# frozen_string_literal: true

class Onboarding::HelpCenterCreationService
  DEFAULT_PORTAL_COLOR = '#1f93ff'
  LOGO_MAX_DOWNLOAD_SIZE = 5.megabytes
  OPERATION_POINTER = 'lla_knowledge_generation_operation_id'

  def initialize(account, user)
    @account = account
    @user = user
  end

  def perform
    portal = find_or_create_onboarding_portal
    attach_brand_logo(portal)
    create_generation_operation(portal)
    portal
  end

  private

  def find_or_create_onboarding_portal
    @account.with_lock do
      portal = @account.portals.find_by(lla_onboarding_key_digest: onboarding_key_digest)
      portal ||= claim_legacy_portal
      portal || @account.portals.create!(portal_attributes.merge(lla_onboarding_key_digest: onboarding_key_digest))
    end
  end

  def claim_legacy_portal
    portal = @account.portals.order(:id).first
    portal&.update!(lla_onboarding_key_digest: onboarding_key_digest)
    portal
  end

  def portal_attributes
    {
      name: portal_name,
      slug: deterministic_slug,
      color: portal_color,
      page_title: portal_name,
      header_text: header_text,
      homepage_link: homepage_link,
      channel_web_widget_id: web_widget_channel_id,
      config: { default_locale: locale, allowed_locales: [locale] }
    }.compact
  end

  def create_generation_operation(portal)
    return if homepage_link.blank?

    Lla::Knowledge::GenerationOperation.transaction do
      @account.lock!
      operation = existing_onboarding_operation(portal) || build_generation_operation(portal)
      @account.update!(custom_attributes: @account.custom_attributes.merge(OPERATION_POINTER => operation.id))
    end
  rescue Lla::Knowledge::ProviderPolicy::Denied => e
    Rails.logger.info("LLA help center generation disabled account_id=#{@account.id} code=#{e.code}")
  end

  def existing_onboarding_operation(portal)
    Lla::Knowledge::GenerationOperation.find_by(
      account: @account,
      portal: portal,
      operation_type: 'onboarding'
    )
  end

  def build_generation_operation(portal)
    Lla::Knowledge::GenerationOperationService.new(
      account: @account,
      portal: portal,
      user: @user,
      idempotency_key: 'onboarding:help-center:v1',
      operation_type: :onboarding,
      event_type: :plan_generation,
      payload: { website_url: homepage_link, locale: locale },
      provider: :direct_fetch,
      capability: :website_analysis
    ).perform
  end

  def attach_brand_logo(portal)
    logo_url = approved_brand_logo_url
    return if logo_url.blank? || portal.logo.attached?
    return unless direct_fetch_permitted?

    SafeFetch.fetch(logo_url, max_bytes: LOGO_MAX_DOWNLOAD_SIZE, allowed_content_type_prefixes: ['image/']) do |logo_file|
      portal.logo.attach(
        io: logo_file.tempfile,
        filename: logo_file.original_filename,
        content_type: logo_file.content_type
      )
    end
  rescue StandardError => e
    Rails.logger.warn("LLA help center logo fallback account_id=#{@account.id} error_class=#{e.class.name}")
  end

  def approved_brand_logo_url
    candidate = Array(brand_info[:logos]).filter_map { |logo| logo.is_a?(Hash) ? logo[:url] : logo }.find(&:present?)
    return if candidate.blank? || homepage_link.blank?
    return unless Lla::Knowledge::UrlPolicy.approved_same_origin?(homepage_link, candidate)

    Lla::Knowledge::UrlPolicy.canonicalize(candidate)
  end

  def direct_fetch_permitted?
    Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: @account,
      provider: :direct_fetch,
      capability: :website_analysis
    )
  end

  def brand_info
    @brand_info ||= (@account.custom_attributes['brand_info'] || {}).deep_symbolize_keys
  end

  def portal_name
    brand_info[:title].presence || @account.name
  end

  def portal_color
    hex = brand_info[:colors]&.first&.dig(:hex)
    hex.to_s.match?(/\A#\h{6}\z/) ? hex : DEFAULT_PORTAL_COLOR
  end

  def header_text
    brand_info[:slogan].presence || brand_info[:description].presence
  end

  def homepage_link
    @homepage_link ||= begin
      raw = @account.custom_attributes['website'].presence || brand_info[:domain].presence
      raw = "https://#{raw}" if raw.present? && !raw.match?(%r{\Ahttps?://}i)
      Lla::Knowledge::UrlPolicy.canonicalize(raw) if raw.present?
    rescue Lla::Knowledge::UrlPolicy::InvalidUrl
      nil
    end
  end

  def web_widget_channel_id
    @account.inboxes.find_by(channel_type: 'Channel::WebWidget')&.channel_id
  end

  def locale
    @account.locale.presence || 'en'
  end

  def onboarding_key_digest
    @onboarding_key_digest ||= Digest::SHA256.hexdigest("lla-help-center-onboarding-v1\0#{@account.id}")
  end

  def deterministic_slug
    base = @account.name.to_s.parameterize.presence || 'portal'
    "#{base.first(60)}-#{@account.id}-help"
  end
end
