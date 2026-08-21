class SuperAdmin::ChannelProvidersController < SuperAdmin::ApplicationController
  PROVIDERS = [
    {
      key: 'zalo_oa',
      name: 'Zalo OA',
      config_key: 'zalo',
      required_configs: %w[ZALO_BRIDGE_URL],
      channel_class: Channel::Api,
      approval: 'Uỷ quyền OA tại bridge',
      description: 'Kênh chính thức qua LLA Zalo bridge; không dùng QR/session cá nhân.'
    },
    {
      key: 'telegram',
      name: 'Telegram',
      channel_class: Channel::Telegram,
      required_configs: [],
      approval: 'Bot token theo từng inbox',
      description: 'Kênh native; trạng thái ở đây chỉ phản ánh hộp thư đã tạo.'
    },
    {
      key: 'facebook',
      name: 'Facebook Messenger',
      config_key: 'facebook',
      platform: 'facebook',
      account_feature: 'channel_facebook',
      channel_class: Channel::FacebookPage,
      required_configs: %w[FB_APP_ID FB_APP_SECRET FB_VERIFY_TOKEN],
      approval: 'Meta App Review / quyền Page',
      description: 'Có sẵn adapter native; cần Meta phê duyệt và OAuth trước khi chạy thật.'
    },
    {
      key: 'instagram',
      name: 'Instagram',
      config_key: 'instagram',
      platform: 'instagram',
      account_feature: 'channel_instagram',
      channel_class: Channel::Instagram,
      required_configs: %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN],
      approval: 'Meta App Review / Instagram Messaging',
      description: 'Có sẵn adapter native; không suy diễn trạng thái kết nối từ cấu hình.'
    },
    {
      key: 'tiktok',
      name: 'TikTok',
      config_key: 'tiktok',
      platform: 'tiktok',
      channel_class: Channel::Tiktok,
      required_configs: %w[TIKTOK_APP_ID TIKTOK_APP_SECRET],
      approval: 'TikTok App Review / Direct Messaging',
      description: 'Có sẵn kênh native; tenant tự mang app thì webhook đăng ký về URL của chính họ.'
    },
    {
      key: 'whatsapp',
      name: 'WhatsApp Business',
      config_key: 'whatsapp_embedded',
      channel_class: Channel::Whatsapp,
      required_configs: %w[WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID],
      approval: 'Meta Embedded Signup / WABA',
      description: 'Có sẵn kênh native; cần cấu hình Meta và hoàn tất Embedded Signup.'
    }
  ].freeze

  def show
    @account_count = Account.count
    @providers = PROVIDERS.map do |provider|
      configured_count = provider[:required_configs].count { |key| configured?(key) }
      inbox_count = inbox_count_for(provider)

      tenant_app_count = tenant_app_count_for(provider)

      provider.merge(
        configured_count: configured_count,
        required_count: provider[:required_configs].length,
        enabled_account_count: enabled_account_count_for(provider),
        inbox_count: inbox_count,
        tenant_app_count: tenant_app_count,
        status: status_for(provider, configured_count, inbox_count, tenant_app_count)
      )
    end
  end

  private

  def configured?(key)
    GlobalConfig.get_value(key).present? || ENV[key].present?
  end

  def inbox_count_for(provider)
    return zalo_inbox_count if provider[:key] == 'zalo_oa'

    provider[:channel_class].count
  end

  def enabled_account_count_for(provider)
    return @account_count unless provider[:account_feature]

    Account.public_send("feature_#{provider[:account_feature]}").count
  end

  def zalo_inbox_count
    scope = Channel::Api.where("additional_attributes ->> 'provider' = ?", 'zalo_oa')
    bridge_url = GlobalConfig.get_value('ZALO_BRIDGE_URL').presence || ENV['ZALO_BRIDGE_URL'].presence
    return scope.count unless bridge_url

    webhook_url = "#{bridge_url.delete_suffix('/')}/webhook/chatwoot"
    scope.or(Channel::Api.where(webhook_url: webhook_url)).count
  end

  # Số tenant đã tự khai ứng dụng nền tảng của mình. Đây là con số làm cho bảng này thôi nói
  # về bản cài đặt và bắt đầu nói về khách: một kênh có thể chưa cấu hình ở cấp cài đặt mà
  # vẫn đang chạy, vì tenant mang ứng dụng của chính họ.
  def tenant_app_count_for(provider)
    return 0 if provider[:platform].blank?

    Lla::PlatformApp.where(platform: provider[:platform]).count
  end

  def status_for(provider, configured_count, inbox_count, tenant_app_count = 0)
    return :inbox_present if inbox_count.positive?
    return :configuration_not_required if provider[:required_configs].empty?
    return :tenant_configured if tenant_app_count.positive?
    return :configured if configured_count == provider[:required_configs].length

    :needs_configuration
  end
end
