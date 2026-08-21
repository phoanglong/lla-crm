# frozen_string_literal: true

class Api::V1::Accounts::CallsController < Api::V1::Accounts::BaseController
  before_action :ensure_voice_enabled

  def index
    result = CallFinder.new(Current.user, Current.account, params).perform
    @calls = result[:calls]
    @calls_count = result[:count]
    @include_sensitive_call_data = Current.account_user&.administrator?
  end

  private

  def ensure_voice_enabled
    return if Current.account.feature_enabled?('channel_voice')

    render json: { error: 'Voice calling is not enabled for this account' }, status: :forbidden
  end
end
