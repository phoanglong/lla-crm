# frozen_string_literal: true

# Tenant khai nhà cung cấp AI **của chính mình**: khoá riêng, endpoint riêng, mô hình riêng.
#
# Khoá đi vào một chiều — nhận thì có, trả ra thì không bao giờ.
class Api::V1::Accounts::Ai::ProvidersController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :fetch_provider, only: [:show, :update, :destroy, :verify]

  def index
    render json: { providers: Current.account.lla_ai_providers.order(:name).map { |provider| serialize(provider) } }
  end

  def show
    render json: serialize(@provider)
  end

  def create
    provider = Current.account.lla_ai_providers.new(provider_params)
    provider.save!
    render json: serialize(provider), status: :created
  end

  def update
    attributes = provider_params.to_h
    # Biểu mẫu không hiển thị lại khoá, nên gửi rỗng nghĩa là "giữ nguyên" chứ không phải "xoá".
    attributes.delete('api_key') if attributes['api_key'].blank?
    @provider.update!(attributes)
    render json: serialize(@provider)
  end

  def destroy
    @provider.destroy!
    head :no_content
  end

  # Gọi thật một lệnh rẻ tiền tới nhà cung cấp. Một cấu hình "trông có vẻ đúng" không nói được
  # gì; chỉ một lệnh gọi đi được mới nói được.
  def verify
    result = Lla::Ai::ProviderVerifier.new(@provider).call
    render json: { ok: result.ok, error: result.error, models: result.models, provider: serialize(@provider.reload) },
           status: result.ok ? :ok : :unprocessable_entity
  end

  private

  def fetch_provider
    @provider = Current.account.lla_ai_providers.find_by!(name: params[:id])
  end

  def serialize(provider)
    {
      name: provider.name,
      kind: provider.kind,
      api_base: provider.api_base,
      api_key_configured: provider.api_key.present?,
      models: provider.model_names,
      enabled: provider.enabled,
      verified_at: provider.verified_at,
      last_error: provider.last_error
    }
  end

  def provider_params
    params.require(:provider).permit(:name, :kind, :api_base, :api_key, :enabled, models: [])
  end
end
