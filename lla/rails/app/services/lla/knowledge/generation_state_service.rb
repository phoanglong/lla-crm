# frozen_string_literal: true

class Lla::Knowledge::GenerationStateService # rubocop:disable Metrics/ClassLength
  class InvalidPlan < StandardError; end
  class InvalidClaim < StandardError; end

  TERMINAL_ITEM_STATES = %w[succeeded failed cancelled].freeze
  TERMINAL_OPERATION_STATES = Lla::Knowledge::GenerationOperation::TERMINAL_STATES
  ERROR_CODE_PATTERN = /\A[a-z0-9_]{3,80}\z/

  def initialize(operation)
    @operation = operation
  end

  def plan!(plan)
    operation.with_lock do
      next operation if operation.state.in?(%w[dispatching running completed completed_with_errors])
      raise InvalidPlan, 'operation is terminal' if operation.terminal?

      normalized = normalize_plan(plan)
      operation.update!(state: 'planning', started_at: operation.started_at || Time.current)
      categories = persist_categories(normalized[:categories])
      persist_items(normalized[:articles], categories)
      operation.update!(state: 'dispatching', expected_items: normalized[:articles].size,
                        claim_digest: nil, claimed_at: nil)
    end
    operation
  end

  def claim_item!(item_id, token:) # rubocop:disable Metrics/AbcSize
    operation.transaction do
      operation.lock!
      item = operation.items.lock.find(item_id)
      next if operation.terminal? || item.state.in?(TERMINAL_ITEM_STATES)
      raise InvalidClaim, 'item already claimed' if item.state == 'claimed'

      if item.attempts >= operation.max_attempts
        finish_failed_item!(item, 'retry_exhausted')
        next
      end

      item.update!(
        state: 'claimed',
        attempts: item.attempts + 1,
        claim_digest: claim_digest(item, token),
        claimed_at: Time.current
      )
      operation.update!(state: 'running') if operation.state.in?(%w[planning dispatching])
      item
    end
  end # rubocop:enable Metrics/AbcSize

  def complete_item!(item_id, token:, article_attributes:)
    operation.transaction do
      operation.lock!
      item = operation.items.lock.find(item_id)
      next item.article if item.state == 'succeeded'

      verify_claim!(item, token)
      article = operation.portal.articles.create!(article_attributes.merge(
                                                    author_id: operation.user_id,
                                                    category_id: item.category_id,
                                                    status: :draft
                                                  ))
      item.update!(state: 'succeeded', article: article, claim_digest: nil, completed_at: Time.current)
      advance_operation!(failed: false)
      article
    end
  end

  def release_item!(item_id, token:, error_code:)
    operation.transaction do
      item = operation.items.lock.find(item_id)
      next if item.state.in?(TERMINAL_ITEM_STATES)

      verify_claim!(item, token)
      item.update!(state: 'pending', claim_digest: nil, claimed_at: nil,
                   last_error_code: normalized_error_code(error_code))
    end
  end

  def fail_item!(item_id, error_code:, token: nil)
    operation.transaction do
      operation.lock!
      item = operation.items.lock.find(item_id)
      next if item.state.in?(TERMINAL_ITEM_STATES)

      verify_claim!(item, token) if token.present?
      finish_failed_item!(item, error_code)
    end
  end

  def terminalize!(state:, error_code: nil) # rubocop:disable Metrics/AbcSize
    raise ArgumentError, 'invalid terminal state' unless state.to_s.in?(TERMINAL_OPERATION_STATES)

    operation.transaction do
      operation.lock!
      next operation if operation.terminal?

      operation.items.where(state: %w[pending claimed]).update_all( # rubocop:disable Rails/SkipsModelValidations
        state: 'cancelled', claim_digest: nil, completed_at: Time.current, updated_at: Time.current
      )
      operation.outboxes.where(state: %w[pending claimed]).update_all( # rubocop:disable Rails/SkipsModelValidations
        state: 'cancelled', claim_digest: nil, updated_at: Time.current
      )
      operation.update!(state: state, last_error_code: normalized_error_code(error_code),
                        claim_digest: nil, claimed_at: nil, completed_at: Time.current,
                        cancelled_at: state.to_s == 'cancelled' ? Time.current : operation.cancelled_at)
    end
    operation
  end # rubocop:enable Metrics/AbcSize

  def status
    {
      status: public_state(operation.state),
      total: operation.expected_items,
      finished: operation.finished_items,
      errors: operation.failed_items
    }
  end

  private

  attr_reader :operation

  def normalize_plan(plan)
    data = plan.is_a?(Hash) ? plan.deep_symbolize_keys : {}
    allowed_urls = Array(data[:allowed_urls]).filter_map { |url| canonical_source(url) }.uniq.first(operation.max_source_urls)
    categories = normalize_categories(data[:categories])
    names = categories.to_h { |category| [category[:name], true] }
    articles = normalize_articles(data[:articles], names, allowed_urls)
    raise InvalidPlan, 'lla_knowledge_plan_empty' if categories.empty? || articles.empty?

    { categories: categories, articles: articles }
  end

  def normalize_categories(values)
    categories = Array(values).first(10).filter_map do |value|
      data = value.is_a?(Hash) ? value.deep_symbolize_keys : {}
      name = data[:name].to_s.squish.first(60)
      next if name.blank?

      { name: name, description: data[:description].to_s.squish.first(200).presence }
    end
    categories.uniq { |category| category[:name] }
  end

  def normalize_articles(values, category_names, allowed_urls) # rubocop:disable Metrics/AbcSize
    allowed = allowed_urls.to_set
    Array(values).first(operation.max_items).filter_map do |value|
      data = value.is_a?(Hash) ? value.deep_symbolize_keys : {}
      category_name = data[:category_name].to_s.squish.first(60)
      next unless category_names[category_name]

      urls = Array(data[:urls]).filter_map { |url| canonical_source(url) }.select { |url| allowed.include?(url) }.uniq.first(3)
      next if urls.empty?

      { title: data[:title].to_s.squish.first(80).presence, category_name: category_name, urls: urls }
    end
  end # rubocop:enable Metrics/AbcSize

  def canonical_source(value)
    url = Lla::Knowledge::UrlPolicy.canonical_source(value)
    return url if Lla::Knowledge::UrlPolicy.approved_same_origin?(operation.portal.homepage_link, url)
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl
    nil
  end

  def persist_categories(categories)
    categories.each_with_index.to_h do |category, index|
      slug = "lla-#{operation.portal_id}-#{operation.id}-#{index + 1}"
      record = operation.portal.categories.create_or_find_by!(slug: slug, locale: operation.portal.default_locale) do |created|
        created.name = category[:name]
        created.description = category[:description]
        created.position = (index + 1) * 10
      end
      [category[:name], record]
    end
  end

  def persist_items(articles, categories)
    articles.each_with_index do |article, index|
      persist_item(article, categories, index)
    end
  end

  def persist_item(article, categories, index) # rubocop:disable Metrics/AbcSize
    item_digest = digest([operation.id, index, article[:category_name], article[:title], *article[:urls]].join("\0"))
    item = operation.items.create!(
      account: operation.account,
      portal: operation.portal,
      category: categories.fetch(article[:category_name]),
      ordinal: index,
      item_key_digest: item_digest,
      source_digest: digest(article[:urls].join("\0"))
    )
    operation.outboxes.create!(
      account: operation.account,
      portal: operation.portal,
      event_type: 'write_article',
      idempotency_digest: digest([operation.id, 'write_article', item_digest].join("\0")),
      available_at: Time.current,
      payload: { generation_item_id: item.id, title: article[:title], urls: article[:urls] }
    )
  end # rubocop:enable Metrics/AbcSize

  def verify_claim!(item, token)
    expected = claim_digest(item, token)
    return if item.state == 'claimed' && item.claim_digest.present? && ActiveSupport::SecurityUtils.secure_compare(item.claim_digest, expected)

    raise InvalidClaim, 'knowledge item claim does not match'
  end

  def claim_digest(item, token)
    digest([operation.id, item.id, token].join("\0"))
  end

  def finish_failed_item!(item, error_code)
    item.update!(state: 'failed', article: nil, claim_digest: nil, completed_at: Time.current,
                 last_error_code: normalized_error_code(error_code))
    advance_operation!(failed: true)
  end

  def advance_operation!(failed:)
    finished = operation.finished_items + 1
    failures = operation.failed_items + (failed ? 1 : 0)
    attributes = { finished_items: finished, failed_items: failures }
    if finished >= operation.expected_items
      attributes[:state] = failures.positive? ? 'completed_with_errors' : 'completed'
      attributes[:completed_at] = Time.current
    else
      attributes[:state] = 'running'
    end
    operation.update!(attributes)
  end

  def normalized_error_code(value)
    code = value.to_s.underscore.gsub(/[^a-z0-9_]/, '_').first(80)
    ERROR_CODE_PATTERN.match?(code) ? code : nil
  end

  def public_state(state)
    state.in?(%w[pending planning dispatching running]) ? 'generating' : state
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end # rubocop:enable Metrics/ClassLength
