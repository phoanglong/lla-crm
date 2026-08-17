# frozen_string_literal: true

class Lla::Knowledge::TranslatedArticleSanitizer
  MAX_TITLE = 200
  MAX_DESCRIPTION = 500
  MAX_CONTENT = 64_000
  UNSAFE_MARKDOWN_URL = /(\]\()\s*(?:javascript|vbscript|data):[^)]*(\))/im

  def self.call(title:, description:, content:)
    {
      title: plain_text(title, MAX_TITLE),
      description: plain_text(description, MAX_DESCRIPTION).presence,
      content: safe_markdown(content)
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
