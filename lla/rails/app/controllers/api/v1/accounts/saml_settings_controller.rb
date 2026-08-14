# frozen_string_literal: true

# Cấu hình SAML ở cấp tài khoản. Hợp đồng API lấy từ MIT
# app/javascript/dashboard/api/samlSettings.js (bọc payload trong khoá
# `saml_settings`, bốn hành động show/create/update/destroy).
class Api::V1::Accounts::SamlSettingsController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :ensure_saml_feature
  before_action :fetch_saml_settings, only: [:show]
  before_action :fetch_saml_settings!, only: [:update, :destroy]

  def show; end

  def create
    @saml_settings = AccountSamlSettings.new(saml_settings_params.merge(account: Current.account))
    @saml_settings.save!
  end

  def update
    @saml_settings.update!(saml_settings_params)
  end

  def destroy
    @saml_settings.destroy!
    head :no_content
  end

  private

  def check_authorization
    authorize(AccountSamlSettings)
  end

  def ensure_saml_feature
    return if Current.account.feature_enabled?('saml')

    render json: { error: I18n.t('errors.saml.feature_not_enabled') }, status: :forbidden
  end

  # Chưa cấu hình thì trả về bản ghi rỗng chứ không 404: giao diện dùng chính
  # phản hồi này để dựng biểu mẫu trống.
  def fetch_saml_settings
    @saml_settings = AccountSamlSettings.find_by(account_id: Current.account.id) ||
                     AccountSamlSettings.new(account: Current.account)
  end

  def fetch_saml_settings!
    @saml_settings = AccountSamlSettings.find_by!(account_id: Current.account.id)
  end

  def saml_settings_params
    params.require(:saml_settings).permit(:sso_url, :certificate, :idp_entity_id, role_mappings: {})
  end
end
