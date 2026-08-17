# frozen_string_literal: true

class Lla::Knowledge::GeneratedArticleSanitizer
  MAX_TITLE = 80
  MAX_DESCRIPTION = 200
  MAX_CONTENT = 18_000
  UNSAFE_MARKDOWN_URL = /(\]\()\s*(?:javascript|vbscript|data):[^)]*(\))/im

  def self.call(payload)
    value = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
    {
      title: plain_text(value[:title], MAX_TITLE),
      description: plain_text(value[:description], MAX_DESCRIPTION).presence,
      content: safe_markdown(value[:content])
    }
  end

  def self.plain_text(value, limit)
    ActionController::Base.helpers.strip_tags(value.to_s).squish.first(limit)
  end
  private_class_method :plain_text

  def self.safe_markdown(value)
    ActionController::Base.helpers.strip_tags(value.to_s)
                          .gsub(UNSAFE_MARKDOWN_URL, '\\1#\\2')
                          .strip
                          .first(MAX_CONTENT)
  end
  private_class_method :safe_markdown
end
