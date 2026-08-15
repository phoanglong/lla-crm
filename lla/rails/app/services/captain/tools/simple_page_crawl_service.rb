# frozen_string_literal: true

# Crawl một trang đơn không cần dịch vụ ngoài: tải HTML, rút tiêu đề/mô tả/
# favicon, gom liên kết (kể cả sitemap.xml) và chuyển body sang markdown.
class Captain::Tools::SimplePageCrawlService
  def initialize(url)
    @url = url
  end

  def success?
    (200..299).cover?(status_code)
  end

  def status_code
    response.code.to_i
  end

  def page_title
    html_document.at_css('title')&.text&.strip.presence
  end

  def meta_description
    html_document.at_css('meta[name="description"]')&.[]('content').presence
  end

  def favicon_url
    href = html_document.at_css('link[rel="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]')&.[]('href')
    return if href.blank?

    absolutize(href)
  end

  # Trang HTML: mọi liên kết <a href> đã tuyệt đối hoá. Sitemap XML: các thẻ <loc>.
  def page_links
    return sitemap_links if sitemap?

    html_document.css('a[href]').filter_map { |anchor| absolutize(anchor['href']) }.uniq
  end

  def body_markdown
    body = html_document.at_css('body')
    return if body.nil?

    ReverseMarkdown.convert(body, unknown_tags: :bypass, github_flavored: true)
  end

  private

  def response
    @response ||= HTTParty.get(@url)
  end

  def html_document
    @html_document ||= Nokogiri::HTML(response.body)
  end

  def sitemap?
    @url.to_s.end_with?('.xml') || response.body.to_s.include?('<urlset')
  end

  def sitemap_links
    Nokogiri::XML(response.body).remove_namespaces!.xpath('//loc').map { |node| node.text.strip }
  end

  def absolutize(href)
    URI.join(@url, href).to_s
  rescue URI::Error
    nil
  end
end
