class Installation::OnboardingController < ApplicationController
  before_action :ensure_installation_onboarding

  def index; end

  def create
    begin
      AccountBuilder.new(
        account_name: onboarding_params.dig(:user, :company),
        user_full_name: onboarding_params.dig(:user, :name),
        email: onboarding_params.dig(:user, :email),
        user_password: params.dig(:user, :password),
        super_admin: true,
        confirmed: true
      ).perform
    rescue StandardError => e
      redirect_to '/', flash: { error: e.message } and return
    end
    finish_onboarding
    redirect_to '/'
  end

  private

  def onboarding_params
    params.permit(user: [:name, :company, :email])
  end

  # Finishing onboarding used to post the owner's company name, name and email
  # address to `hub.2.chatwoot.com` with `subscribed_to_mailers: true`, behind a
  # `subscribe_to_updates` checkbox on the installation form. Nothing leaves the
  # installation now, so the checkbox and the parameter are gone with it.
  def finish_onboarding
    ::Redis::Alfred.delete(::Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
  end

  def ensure_installation_onboarding
    redirect_to '/' unless ::Redis::Alfred.get(::Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
  end
end
