# frozen_string_literal: true

# Onboarding Zalo OA tự phục vụ.
#
# Người vận hành tenant chỉ nhập App ID + App Secret; phần còn lại — tạo kết nối ở
# cầu, tạo hộp thư, gắn hai thứ đó với nhau, và trả về đúng những URL cần dán vào
# developers.zalo.me — do phía máy chủ làm, để token quản trị của cầu không bao giờ
# xuất hiện trong trình duyệt.
class Api::V1::Accounts::Zalo::ConnectionsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :ensure_bridge_configured

  # Danh sách sự kiện phải bật ở Zalo Developers. Để ở đây, không để trong giao diện,
  # vì cầu và màn hình phải nói cùng một danh sách.
  REQUIRED_EVENTS = %w[
    user_send_text
    user_send_image
    user_send_file
    user_send_sticker
    user_send_link
    user_send_location
    follow
    unfollow
  ].freeze

  def show
    connection = Lla::Zalo::BridgeClient.connection(params[:id])
    render json: payload(connection, inbox_for(connection))
  rescue Lla::Zalo::BridgeClient::NotFound
    render json: { error: I18n.t('errors.zalo.connection_not_found') }, status: :not_found
  end

  def create
    connection = Lla::Zalo::BridgeClient.create_connection(
      name: connection_params[:name].presence || 'Zalo OA',
      app_id: connection_params[:app_id],
      app_secret: connection_params[:app_secret],
      oa_id: connection_params[:oa_id]
    )
    inbox = build_inbox!(connection)
    bound = Lla::Zalo::BridgeClient.bind_connection(
      connection['id'],
      account_id: Current.account.id,
      inbox_id: inbox.id,
      webhook_secret: inbox.channel.secret
    )
    render json: payload(bound, inbox), status: :created
  rescue Lla::Zalo::BridgeClient::InvalidCredentials
    render json: { error: I18n.t('errors.zalo.invalid_app_credentials') }, status: :unprocessable_entity
  end

  # Kiểm tra bản ghi TXT xác minh tên miền — bước duy nhất trong quy trình Zalo mà
  # người vận hành phải làm ở nhà cung cấp DNS, và cũng là bước hay quên nhất.
  def domain_check
    render json: Lla::Zalo::DomainVerification.check(params[:domain], expected: params[:code])
  rescue Lla::Zalo::DomainVerification::InvalidDomain
    render json: { error: I18n.t('errors.zalo.invalid_domain') }, status: :unprocessable_entity
  end

  private

  def ensure_bridge_configured
    return if Lla::Zalo::BridgeClient.configured?

    render json: { error: I18n.t('errors.zalo.bridge_not_configured') }, status: :service_unavailable
  end

  # Hộp thư Zalo là một hộp thư API mang webhook trỏ về đúng kết nối của nó. Nếu
  # tạo hộp thư mà không gắn được vào cầu thì hộp thư đó vô dụng — nên cả hai đi
  # chung một giao dịch, và lỗi ở bước gắn sẽ kéo hộp thư đi cùng.
  def build_inbox!(connection)
    ActiveRecord::Base.transaction do
      channel = Channel::Api.create!(
        account: Current.account,
        webhook_url: connection['chatwoot_webhook_url'],
        additional_attributes: {
          'provider' => 'zalo_oa',
          'bridge_url' => Lla::Zalo::BridgeClient.base_url,
          'zalo_connection_id' => connection['id'],
          'zalo_app_id' => connection['app_id']
        }
      )
      Current.account.inboxes.create!(name: connection['name'], channel: channel)
    end
  end

  def inbox_for(connection)
    Current.account.inboxes
           .joins("INNER JOIN channel_api ON channel_api.id = inboxes.channel_id AND inboxes.channel_type = 'Channel::Api'")
           .find_by("channel_api.additional_attributes->>'zalo_connection_id' = ?", connection['id'].to_s)
  end

  # Danh sách kiểm tra là thứ màn hình onboarding vẽ ra. Mỗi mục trả lời được bằng
  # một sự thật đo được, không phải bằng "người dùng nói đã làm".
  def payload(connection, inbox)
    {
      connection: connection,
      inbox: inbox && { id: inbox.id, name: inbox.name, channel_type: inbox.channel_type },
      required_events: REQUIRED_EVENTS,
      checks: checks(connection, inbox)
    }
  end

  def checks(connection, inbox)
    status = connection['status'] || {}
    [
      { key: 'inbox_created', ok: inbox.present? },
      { key: 'inbox_linked', ok: status['inbox_linked'] == true && inbox.present? && inbox.id.to_s == connection['inbox_id'].to_s },
      { key: 'outbound_signature', ok: status['outbound_secret_set'] == true },
      { key: 'oauth_authorized', ok: status['authorized'] == true },
      { key: 'webhook_received', ok: status['webhook_received'] == true },
      { key: 'message_received', ok: status['last_inbound_at'].present? },
      { key: 'message_sent', ok: status['last_outbound_at'].present? }
    ]
  end

  def connection_params
    params.require(:connection).permit(:name, :app_id, :app_secret, :oa_id)
  end
end
