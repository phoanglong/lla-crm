# frozen_string_literal: true

# Công cụ HTTP tuỳ chỉnh: thực thi cấu hình Captain::CustomTool (Toolable) —
# render URL/body, gắn header xác thực + metadata, gọi Net::HTTP và định dạng
# phản hồi. Sang origin khác khi redirect thì bỏ header xác thực.
class Captain::Tools::HttpTool < Captain::Tools::BasePublicTool
  MAX_REDIRECTS = 5

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
    Rails.logger.error("HttpTool execution error (#{@custom_tool.slug}): #{e.class} #{e.message}")
    'An error occurred while executing the request'
  end

  private

  def execute_request(url, body, metadata_headers)
    response = perform_with_redirects(URI.parse(url), body, metadata_headers, @custom_tool.build_auth_headers)
    raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  # Tự theo redirect để kiểm soát header: sang origin khác thì BỎ header xác thực.
  def perform_with_redirects(uri, body, headers, auth_headers)
    origin = origin_of(uri)
    response = nil

    (MAX_REDIRECTS + 1).times do
      applied_auth = origin_of(uri) == origin ? auth_headers : {}
      response = single_request(uri, body, headers.merge(applied_auth))
      break unless response.is_a?(Net::HTTPRedirection) && response['location'].present?

      uri = URI.join(uri.to_s, response['location'])
    end

    response
  end

  def single_request(uri, body, headers)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 10
    http.read_timeout = 15

    http.request(build_request(uri, body, headers))
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
end
