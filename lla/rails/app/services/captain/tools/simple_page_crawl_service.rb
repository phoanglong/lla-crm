# frozen_string_literal: true

require 'net/http'

# Crawl một trang đơn không cần dịch vụ ngoài: tải HTML, rút tiêu đề/mô tả/
# favicon, gom liên kết (kể cả sitemap.xml) và chuyển body sang markdown.
class Captain::Tools::SimplePageCrawlService
  MAX_REDIRECTS = 3
  MAX_RESPONSE_BYTES = 2.megabytes
  MAX_DISCOVERED_LINKS = 100

  Response = Struct.new(:code, :body, :final_uri, :location, keyword_init: true)

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

  # Chỉ trả liên kết cùng origin để một tài liệu không thể biến thành trình
  # quét host tùy ý. Mỗi URL vẫn được kiểm tra SSRF lại khi parser fetch.
  def page_links
    links = if sitemap?
              sitemap_links
            else
              html_document.css('a[href]').filter_map { |anchor| absolutize(anchor['href']) }
            end

    links.select { |link| Lla::Network::UrlSafety.same_origin?(response.final_uri, link) }
         .uniq
         .first(MAX_DISCOVERED_LINKS)
  end

  def body_markdown
    body = html_document.at_css('body')
    return if body.nil?

    ReverseMarkdown.convert(body, unknown_tags: :bypass, github_flavored: true)
  end

  private

  def response
    @response ||= fetch(@url)
  end

  def fetch(url, redirect_count = 0)
    raise 'Too many redirects' if redirect_count > MAX_REDIRECTS

    validated = Lla::Network::UrlSafety.validate!(url)
    result = request_once(validated)
    return result unless redirect_response?(result)

    redirect_url = URI.join(validated.uri.to_s, result.location).to_s
    fetch(redirect_url, redirect_count + 1)
  end

  def request_once(validated)
    result = nil
    build_http(validated).start do |client|
      request = Net::HTTP::Get.new(validated.uri, 'User-Agent' => 'LLA-CaptainCrawler/1.0')
      client.request(request) { |net_response| result = buffered_response(net_response, validated.uri) }
    end
    result
  end

  def build_http(validated)
    uri = validated.uri
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = validated.ip_address
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 15
    http
  end

  def buffered_response(net_response, uri)
    body = +''
    net_response.read_body do |chunk|
      body << chunk
      raise 'Response body is too large' if body.bytesize > MAX_RESPONSE_BYTES
    end
    Response.new(code: net_response.code, body: body, final_uri: uri, location: net_response['location'])
  end

  def redirect_response?(result)
    (300..399).cover?(result.code.to_i) && result.location.present?
  end

  def html_document
    @html_document ||= Nokogiri::HTML(response.body)
  end

  def sitemap?
    @url.to_s.end_with?('.xml') || response.body.to_s.include?('<urlset')
  end

  def sitemap_links
    Nokogiri::XML(response.body).remove_namespaces!.xpath('//loc').filter_map { |node| absolutize(node.text.strip) }
  end

  def absolutize(href)
    uri = URI.join(response.final_uri.to_s, href)
    return unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.fragment = nil
    uri.to_s
  rescue URI::Error
    nil
  end
end
