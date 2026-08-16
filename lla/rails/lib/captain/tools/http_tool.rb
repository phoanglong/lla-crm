# frozen_string_literal: true

require 'net/http'
require 'uri'

# Công cụ HTTP tuỳ chỉnh: thực thi cấu hình Captain::CustomTool (Toolable) —
# render URL/body, gắn header xác thực + metadata, gọi Net::HTTP và định dạng
# phản hồi. Redirect khác origin bị chặn trước khi gửi auth/body/metadata.
class Captain::Tools::HttpTool < Captain::Tools::BasePublicTool
  MAX_REDIRECTS = 5
  MAX_REQUEST_BYTES = 256.kilobytes
  MAX_RESPONSE_BYTES = 1.megabyte

  Response = Struct.new(:code, :body, :location, keyword_init: true)

  def initialize(assistant, custom_tool)
    @custom_tool = custom_tool
    super(assistant)
  end

  # Mỗi custom tool là một "tool" riêng dưới mắt LLM — tên/mô tả/tham số lấy từ
  # cấu hình chứ không phải từ class.
  def name
    @custom_tool.slug
  end

  def description
    @custom_tool.description.presence || @custom_tool.title
  end

  def parameters
    @parameters ||= Array(@custom_tool.param_schema).each_with_object({}) do |param, hash|
      param_name = param['name'].to_sym
      hash[param_name] = RubyLLM::Parameter.new(
        param_name,
        type: param['type'].presence || 'string',
        desc: param['description'],
        required: param.fetch('required', false)
      )
    end
  end

  def active?
    @custom_tool.enabled?
  end

  def perform(tool_context, **params)
    url = @custom_tool.build_request_url(params)
    body = @custom_tool.build_request_body(params)
    response = execute_request(url, body, @custom_tool.build_metadata_headers(tool_context.state))

    @custom_tool.format_response(response)
  rescue StandardError => e
    Rails.logger.error("HttpTool execution error (#{@custom_tool.slug}): #{e.class}")
    'An error occurred while executing the request'
  end

  private

  def execute_request(url, body, metadata_headers)
    raise 'Request body is too large' if body.to_s.bytesize > MAX_REQUEST_BYTES

    response = perform_with_redirects(URI.parse(url), body, metadata_headers, @custom_tool.build_auth_headers)
    raise "HTTP #{response.code}" unless success_response?(response)

    response.body
  end

  # Chỉ theo redirect cùng origin. Điều này giữ auth, metadata và POST body khỏi
  # bị chuyển sang một host do endpoint từ xa kiểm soát.
  def perform_with_redirects(uri, body, headers, auth_headers)
    origin = origin_of(uri)
    response = nil

    (MAX_REDIRECTS + 1).times do
      validated = Lla::Network::UrlSafety.validate!(uri.to_s)
      response = single_request(validated, body, headers.merge(auth_headers))
      break unless redirect_response?(response)
      raise Lla::Network::UrlSafety::UnsafeUrlError, 'redirects are not allowed for POST tools' if @custom_tool.http_method == 'POST'

      redirect_uri = URI.join(uri.to_s, response.location)
      raise Lla::Network::UrlSafety::UnsafeUrlError, 'cross-origin redirects are not allowed' unless origin_of(redirect_uri) == origin

      uri = redirect_uri
    end

    raise 'Too many redirects' if redirect_response?(response)

    response
  end

  def single_request(validated_url, body, headers)
    result = nil
    build_http(validated_url).start do |client|
      request = build_request(validated_url.uri, body, headers)
      client.request(request) { |net_response| result = buffered_response(net_response) }
    end
    result
  end

  def build_http(validated_url)
    uri = validated_url.uri
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = validated_url.ip_address
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 15
    http
  end

  def buffered_response(net_response)
    response_body = +''
    net_response.read_body do |chunk|
      response_body << chunk
      raise 'Response body is too large' if response_body.bytesize > MAX_RESPONSE_BYTES
    end
    Response.new(code: net_response.code, body: response_body, location: net_response['location'])
  end

  def build_request(uri, body, headers)
    if @custom_tool.http_method == 'POST'
      request = Net::HTTP::Post.new(uri, headers.merge('Content-Type' => 'application/json'))
      request.body = body
    else
      request = Net::HTTP::Get.new(uri, headers)
    end
    apply_basic_auth(request)
    request
  end

  def apply_basic_auth(request)
    credentials = @custom_tool.build_basic_auth_credentials
    request.basic_auth(*credentials) if credentials
  end

  def origin_of(uri)
    [uri.scheme, uri.host, uri.port]
  end

  def success_response?(response)
    (200..299).cover?(response.code.to_i)
  end

  def redirect_response?(response)
    (300..399).cover?(response.code.to_i) && response.location.present?
  end
end
