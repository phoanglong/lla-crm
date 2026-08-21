# frozen_string_literal: true

class Lla::Knowledge::ArticleSearchDocument
  MAX_TERMS = 8
  MAX_TERM_BYTES = 2_000
  MAX_CONTENT_BYTES = 24_000

  def self.digest(article)
    Digest::SHA256.hexdigest(JSON.generate(
                               title: article.title.to_s,
                               description: article.description.to_s,
                               content: article.content.to_s
                             ))
  end

  def self.terms(article)
    title = normalize(article.title)
    description = normalize(article.description)
    content = normalize(article.content, maximum: MAX_CONTENT_BYTES)
    paragraphs = content.split(/\n{2,}|(?<=[.!?])\s+/).filter_map { |value| bounded(value) }

    [title, [title, description].compact_blank.join(' — '), description, *paragraphs]
      .filter_map { |value| bounded(value) }
      .uniq
      .first(MAX_TERMS)
  end

  def self.normalize(value, maximum: MAX_TERM_BYTES)
    text = ActionController::Base.helpers
                                 .strip_tags(value.to_s.scrub)
                                 .gsub(/[`*_>#|~-]+/, ' ')
                                 .squish
    bounded(text, maximum: maximum)
  end
  private_class_method :normalize

  def self.bounded(value, maximum: MAX_TERM_BYTES)
    text = value.to_s.squish
    return if text.blank?

    text.byteslice(0, maximum).to_s.scrub
  end
  private_class_method :bounded
end
