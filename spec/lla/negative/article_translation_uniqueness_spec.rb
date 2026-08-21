# frozen_string_literal: true

require 'rails_helper'

# Wave G3 added `idx_lla_articles_unique_translation` — one translation per
# (portal, root article, locale) — but stated the rule only in the database. The
# community controller creates an article and then rewrites `associated_article_id`
# to the root of the chain, so an ordinary POST could collide with a translation
# that already existed, raise `ActiveRecord::RecordNotUnique` out of a path nothing
# rescues, and answer **500**.
#
# Two things are asserted here: the invariant still holds, and a caller who trips it
# is told so instead of getting a server error.
RSpec.describe 'Article translation uniqueness', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:portal) do
    create(:portal, account: account, config: { allowed_locales: %w[en fr], default_locale: 'en' })
  end
  let(:category_en) { create(:category, portal: portal, account_id: account.id, locale: 'en', slug: 'cat-en') }
  let(:category_fr) { create(:category, portal: portal, account_id: account.id, locale: 'fr', slug: 'cat-fr') }
  let(:root) do
    create(:article, portal: portal, category: category_en, account_id: account.id,
                     author_id: administrator.id, associated_article_id: nil)
  end

  def post_article(category, associated_article_id, slug:)
    post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/articles",
         params: { article: { category_id: category.id, title: 'T', slug: slug, content: 'C',
                              author_id: administrator.id, associated_article_id: associated_article_id } },
         headers: administrator.create_new_auth_token, as: :json
  end

  it 'accepts one translation per locale' do
    post_article(category_fr, root.id, slug: 'fr-translation')

    expect(response).to have_http_status(:success)
    expect(Article.find(response.parsed_body['payload']['id']).associated_article_id).to eq(root.id)
  end

  it 'refuses a second translation in a locale the root already has, with 422 rather than 500' do
    create(:article, portal: portal, category: category_fr, account_id: account.id,
                     author_id: administrator.id, associated_article_id: root.id, slug: 'fr-first')

    post_article(category_fr, root.id, slug: 'fr-second')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include('idx_lla_articles_unique_translation')
  end

  # The controller resolves a submitted parent to the root of the chain, so pointing
  # at a translation is the same collision wearing a different hat — and it is the
  # exact shape that produced the 500.
  it 'refuses a collision reached through a parent that resolves to the same root' do
    parent = create(:article, portal: portal, category: category_fr, account_id: account.id,
                              author_id: administrator.id, associated_article_id: root.id, slug: 'fr-parent')

    post_article(category_fr, parent.id, slug: 'fr-child')

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'still refuses the collision at the database boundary if the application check is bypassed' do
    create(:article, portal: portal, category: category_fr, account_id: account.id,
                     author_id: administrator.id, associated_article_id: root.id, slug: 'fr-only')

    expect do
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO articles (account_id, portal_id, category_id, author_id, title, slug, locale,
                              associated_article_id, status, lla_search_content_digest, lla_search_version,
                              created_at, updated_at)
        VALUES (#{account.id}, #{portal.id}, #{category_fr.id}, #{administrator.id},
                'raw', 'fr-raw', 'fr', #{root.id}, 0, '#{'0' * 64}', 1, NOW(), NOW())
      SQL
    end.to raise_error(ActiveRecord::RecordNotUnique, /idx_lla_articles_unique_translation/)
  end
end
