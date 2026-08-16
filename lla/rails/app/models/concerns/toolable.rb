# frozen_string_literal: true

# Hành vi "công cụ HTTP" cho Captain::CustomTool: render template liquid cho
# URL/body/phản hồi, dựng header xác thực + metadata X-LLA-* và tạo
# instance HttpTool chạy trong agent.
module Concerns::Toolable
  extend ActiveSupport::Concern

  def build_request_url(params)
    render_liquid(endpoint_url, params)
  end

  def build_request_body(params)
    return if request_template.blank?

    render_liquid(request_template, params)
  end

  def build_auth_headers
    if auth_bearer?
      { 'Authorization' => "Bearer #{auth_config['token']}" }
    elsif auth_api_key?
      { auth_config['name'] => auth_config['key'] }
    else
      {}
    end
  end

  def build_basic_auth_credentials
    return unless auth_basic?

    [auth_config['username'], auth_config['password']]
  end

  # response_template đọc payload JSON của API qua biến `response`;
  # payload không phải JSON thì giữ nguyên chuỗi thô.
  def format_response(raw_response)
    return raw_response if response_template.blank?

    Liquid::Template.parse(response_template).render('response' => parse_response_body(raw_response))
  end

  # Header ngữ cảnh gửi kèm để hệ thống đối tác nhận diện nguồn gọi.
  # Không gửi email/số điện thoại: endpoint tùy chỉnh phải tra cứu dữ liệu qua
  # integration đã được ủy quyền, không nhận PII ngầm từ agent runtime.
  def build_metadata_headers(state)
    headers = { 'X-LLA-Tool-Slug' => slug }
    headers['X-LLA-Account-Id'] = state[:account_id].to_s if state[:account_id]
    headers['X-LLA-Assistant-Id'] = state[:assistant_id].to_s if state[:assistant_id]
    headers.merge!(conversation_metadata_headers(state[:conversation]))
    headers.merge!(contact_inbox_metadata_headers(state[:contact_inbox]))
    headers.merge!(contact_metadata_headers(state[:contact]))
    headers
  end

  def to_tool_metadata
    { id: slug, title: title, description: description, custom: true }
  end

  def tool(assistant)
    Captain::Tools::HttpTool.new(assistant, self)
  end

  private

  def render_liquid(template, params)
    Liquid::Template.parse(template).render((params || {}).deep_stringify_keys)
  end

  def parse_response_body(raw_response)
    JSON.parse(raw_response)
  rescue JSON::ParserError
    raw_response
  end

  def conversation_metadata_headers(conversation)
    return {} if conversation.blank?

    {
      'X-LLA-Conversation-Id' => conversation[:id].to_s,
      'X-LLA-Conversation-Display-Id' => conversation[:display_id].to_s
    }
  end

  def contact_inbox_metadata_headers(contact_inbox)
    headers = { 'X-LLA-Contact-Inbox-Verified' => (contact_inbox&.dig(:hmac_verified) || false).to_s }
    headers['X-LLA-Contact-Inbox-Id'] = contact_inbox[:id].to_s if contact_inbox&.dig(:id)
    headers
  end

  def contact_metadata_headers(contact)
    return {} if contact.blank?

    { 'X-LLA-Contact-Id' => contact[:id].to_s }
  end
end
