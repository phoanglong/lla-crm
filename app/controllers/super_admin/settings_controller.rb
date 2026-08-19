class SuperAdmin::SettingsController < SuperAdmin::ApplicationController
  def show; end

  # This used to run the version check, whose only action was to ask Chatwoot's
  # hosted hub for the latest release — and to pay for the answer by posting this
  # installation's metrics. There is nothing remote left to refresh, so the page
  # simply re-renders from local state.
  def refresh
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_to super_admin_settings_path, notice: 'Instance status refreshed'
    # rubocop:enable Rails/I18nLocaleTexts
  end
end
