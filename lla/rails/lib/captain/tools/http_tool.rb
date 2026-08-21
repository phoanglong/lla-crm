# frozen_string_literal: true

require 'net/http'
require 'uri'

# Công cụ HTTP tuỳ chỉnh: thực thi cấu hình Captain::CustomTool (Toolable) —
# render URL/body, gắn header xác thực + metadata, gọi Net::HTTP và định dạng
# phản hồi. Redirect khác origin bị chặn trước khi gửi auth/body/metadata.
class Captain::Tools::HttpTool < Captain::Tools::BasePublicTool
  MAX_REDIRECTS = 5
  MAX_REQUEST_BYTES = 256.kilobytes
  MAX_RESPONSE_BYTES = 256.kilobytes
  MAX_TOOL_OUTPUT_BYTES = 32_000

  Response = Struct.new(:code, :body, :location, :content_type, keyword_init: true)

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
    runtime_tool_valid?
  end

  def perform(tool_context, **params)
    raise 'Custom tool is unavailable' unless runtime_tool_valid?

    result = nil
    @custom_tool.with_lock do
      @custom_tool.reload
      raise 'Custom tool is unavailable' unless runtime_tool_valid?

      response = perform_request(params, tool_context&.state || {})
      raise "HTTP #{response.code}" unless success_response?(response)

      result = @custom_tool.format_response(response.body)
    end
    result.to_s.byteslice(0, MAX_TOOL_OUTPUT_BYTES).to_s.scrub
  rescue StandardError => e
    Rails.logger.error("HttpTool execution error (#{@custom_tool.slug}): #{e.class}")
    'An error occurred while executing the request'
  end

  def perform_test(account:, **params)
    raise 'Custom tool is unavailable' unless test_tool_valid?(account)

    response = perform_request(params, account_id: account.id)
    {
      status: response.code.to_i,
      response_bytes: response.body.to_s.bytesize,
      content_type: response.content_type.to_s.byteslice(0, 120).to_s.scrub
    }
  end

  private

  def perform_request(params, state)
    url = @custom_tool.build_request_url(params)
    body = @custom_tool.build_request_body(params)
    raise 'Request body is too large' if body.to_s.bytesize > MAX_REQUEST_BYTES

    metadata_headers = @custom_tool.build_metadata_headers(state.deep_symbolize_keys)
    perform_with_redirects(URI.parse(url), body, metadata_headers, @custom_tool.build_auth_headers)
  end

  def runtime_tool_valid?
    valid_runtime_records? && custom_tools_enabled_for_account_id?(assistant.account_id)
  end

  def valid_runtime_records?
    assistant&.persisted? && @custom_tool&.persisted? && @custom_tool.enabled? && @custom_tool.valid? &&
      @custom_tool.account_id == assistant.account_id
  end

  def test_tool_valid?(account)
    @custom_tool.account_id == account.id && @custom_tool.valid? && custom_tools_enabled_for_account_id?(account.id)
  end

  def custom_tools_enabled_for_account_id?(account_id)
    account = Account.find_by(id: account_id)
    account.present? && Captain::Assistant.custom_http_tools_enabled_for?(account)
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
    Response.new(
      code: net_response.code,
      body: response_body,
      location: net_response['location'],
      content_type: net_response['content-type']
    )
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
