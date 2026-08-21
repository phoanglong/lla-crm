# frozen_string_literal: true

# Thử một lệnh gọi thật tới nhà cung cấp của tenant.
#
# "Đã điền đủ trường" không phải là bằng chứng gì cả — khoá sai, endpoint sai, mạng chặn đều
# trông giống nhau cho tới khi gọi. Ở đây gọi liệt kê mô hình: rẻ nhất, và trả về đúng thứ
# màn hình cần để gợi ý mô hình.
class Lla::Ai::ProviderVerifier
  Result = Struct.new(:ok, :error, :models, keyword_init: true)

  TIMEOUT = 10
  MAX_MODELS_RETURNED = Lla::Ai::Provider::MAX_MODELS
  # Đường liệt kê mô hình theo từng giao thức.
  LIST_PATHS = {
    'openai' => '/v1/models',
    'openai_compatible' => '/models',
    'azure_openai' => '/openai/models?api-version=2024-10-21',
    'anthropic' => '/v1/models',
    'gemini' => '/v1beta/models'
  }.freeze
  DEFAULT_BASES = {
    'openai' => 'https://api.openai.com',
    'anthropic' => 'https://api.anthropic.com',
    'gemini' => 'https://generativelanguage.googleapis.com'
  }.freeze

  def initialize(provider)
    @provider = provider
  end

  def call
    response = HTTParty.get(list_url, headers: headers, timeout: TIMEOUT, follow_redirects: false)
    return failure("HTTP #{response.code}") unless response.code.to_i.between?(200, 299)

    # Danh sách mô hình được ghi ngay tại đây. Trước đó màn hình phải gọi thêm một lệnh cập
    # nhật để lưu lại, và lệnh ấy hỏng trong im lặng thì kết nối hiện là "đã kiểm tra" nhưng
    # không có mô hình nào — đúng trạng thái vô nghĩa nhất.
    @provider.update!(models: extract_models(response), verified_at: Time.current, last_error: nil)
    Result.new(ok: true, error: nil, models: @provider.model_names)
  rescue Timeout::Error, Errno::ETIMEDOUT
    failure('timeout')
  rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError, HTTParty::Error, JSON::ParserError
    failure('unreachable')
  end

  private

  def base
    (@provider.api_base.presence || DEFAULT_BASES[@provider.kind]).to_s.chomp('/')
  end

  def list_url
    path = LIST_PATHS.fetch(@provider.kind)
    # Endpoint tương thích OpenAI thường đã bao gồm `/v1`, nên không nối thêm lần nữa.
    "#{base}#{path}"
  end

  def headers
    case @provider.kind
    when 'anthropic'
      { 'x-api-key' => @provider.api_key.to_s, 'anthropic-version' => '2023-06-01' }
    when 'gemini'
      { 'x-goog-api-key' => @provider.api_key.to_s }
    when 'azure_openai'
      { 'api-key' => @provider.api_key.to_s }
    else
      { 'Authorization' => "Bearer #{@provider.api_key}" }
    end
  end

  # Mỗi nhà cung cấp gói danh sách một kiểu, nhưng đều là một mảng có `id` hoặc `name`.
  def extract_models(response)
    entries(response.parsed_response)
      .filter_map { |entry| model_id(entry) }
      .first(MAX_MODELS_RETURNED)
  end

  def entries(body)
    return [] unless body.is_a?(Hash)

    body['data'] || body['models'] || []
  end

  # Gemini trả `models/gemini-...`; bỏ tiền tố để tên dùng được y như khi gọi.
  def model_id(entry)
    id = entry.is_a?(Hash) ? (entry['id'] || entry['name']) : entry
    id.presence && id.to_s.delete_prefix('models/')
  end

  # Lý do hỏng được ghi lại để người vận hành thấy, nhưng không bê nguyên văn phản hồi của
  # nhà cung cấp ra ngoài — thân phản hồi lỗi có khi chứa lại chính khoá vừa gửi đi.
  def failure(reason)
    @provider.update!(verified_at: nil, last_error: reason)
    Result.new(ok: false, error: reason, models: [])
  end
end
