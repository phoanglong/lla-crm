json.id portal.id
json.color portal.color
json.custom_domain portal.custom_domain
json.header_text portal.header_text
json.homepage_link portal.homepage_link
json.name portal.name
json.page_title portal.page_title
json.slug portal.slug
json.archived portal.archived
json.account_id portal.account_id

json.config do
  json.allowed_locales do
    json.array! portal.allowed_locale_codes.each do |locale|
      json.partial! 'api/v1/models/portal_config', formats: [:json], locale: locale, portal: portal
    end
  end
  json.default_locale portal.default_locale
  json.layout portal.layout
  json.social_profiles portal.social_profiles
  json.locale_translations portal.config['locale_translations'] || {}
  json.popular_content portal.config['popular_content'] || {}
end

if portal.channel_web_widget
  json.inbox do
    json.partial! 'api/v1/models/inbox', formats: [:json], resource: portal.channel_web_widget.inbox
  end
end

json.logo portal.file_base_data if portal.logo.present?

json.meta do
  json.all_articles_count articles.try(:size)
  json.archived_articles_count articles.try(:archived).try(:size)
  json.published_count articles.try(:published).try(:size)
  json.draft_articles_count articles.try(:draft).try(:size)
  json.mine_articles_count articles.search_by_author(current_user.id).try(:size) if current_user.present? && articles.any?
  json.categories_count portal.categories.try(:size)
  json.default_locale portal.default_locale
end

# Always emitted, including for a portal with no custom domain: the dashboard reads
# capability, provider readiness and the caller's permission from here, so omitting
# the key would render an administrator as unable to manage the domain.
json.ssl_settings Lla::CustomDomains::StatusPresenter.call(portal: portal, account_user: Current.account_user)
