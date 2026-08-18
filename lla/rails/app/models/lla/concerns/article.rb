# frozen_string_literal: true

module Lla::Concerns::Article
  extend ActiveSupport::Concern

  included do
    has_many :article_embeddings, dependent: :delete_all

    before_validation :prepare_lla_search_index,
                      if: -> { will_save_change_to_title? || will_save_change_to_description? || will_save_change_to_content? }
    after_commit :enqueue_lla_search_rebuild,
                 if: -> { saved_change_to_lla_search_content_digest? }

    # Wave G3 added `idx_lla_articles_unique_translation` — one translation per
    # (portal, root article, locale) — because the community schema let a root
    # accumulate several articles in the same language and left the reader to guess
    # which one to serve. The database is the boundary that has to hold, but nothing
    # answered for it in the application, so a perfectly ordinary POST that collided
    # raised `ActiveRecord::RecordNotUnique` out of an unrescued path and the API
    # returned 500. The rule is now stated where a user can be told about it.
    validate :lla_translation_is_unique_for_locale, if: :associated_article_id?
  end

  class_methods do
    def vector_search(params)
      portal = Portal.find_by(account_id: params[:account_id], id: params[:portal_id])
      return none if portal.blank?

      Lla::Knowledge::ArticleSemanticSearch.new(
        scope: all,
        portal: portal,
        query: params[:query],
        filters: params,
        requester_key: params[:requester_key]
      ).perform
    end
  end

  def generate_article_search_terms
    Lla::Knowledge::ArticleSearchDocument.terms(self)
  end

  def generate_and_save_article_seach_terms
    operation = Lla::Knowledge::IndexOperationService.new(article: self).perform
    Lla::Knowledge::GenerationOutboxDispatchJob.perform_later(operation.id)
    operation
  end

  private

  # `Article#associate_root_article` rewrites `associated_article_id` to the root of
  # the chain *after* create, so the value validated here is whatever the caller
  # sent; the root it resolves to is checked as well, which is the collision the
  # community controller actually produces.
  def lla_translation_is_unique_for_locale
    return if portal.blank?

    parent = portal.articles.find_by(id: associated_article_id)
    roots = [associated_article_id, parent && self.class.find_root_article_id(parent)].compact.uniq
    return if roots.empty?

    siblings = portal.articles.where(associated_article_id: roots, locale: locale)
    siblings = siblings.where.not(id: id) if persisted?
    return unless siblings.exists?

    errors.add(:associated_article_id,
               I18n.t('errors.articles.translation_taken',
                      default: 'already has a translation in this locale'))
  end

  def prepare_lla_search_index
    next_digest = Lla::Knowledge::ArticleSearchDocument.digest(self)
    return if next_digest == lla_search_content_digest

    self.lla_search_content_digest = next_digest
    self.lla_search_version = new_record? ? 1 : [lla_search_version.to_i + 1, 1].max
  end

  def enqueue_lla_search_rebuild
    return unless account.feature_enabled?('help_center_embedding_search')
    return unless Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: account, provider: :openai, capability: :embedding_search
    )

    generate_and_save_article_seach_terms
  rescue Lla::Knowledge::ProviderPolicy::Denied, Lla::Knowledge::IndexOperationService::InvalidRequest
    nil
  end
end
