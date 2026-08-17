# frozen_string_literal: true

# Public Cloudflare-compatible ownership challenge endpoint. It is present in
# pure LLA mode, but returns an indistinguishable 404 until the LLA custom-domain
# capability is explicitly enabled and a non-expired challenge exists.
class CustomDomainsController < ApplicationController
  def verify
    return head :not_found unless Lla::Knowledge::ProviderPolicy.capability_enabled?(:custom_domains)

    body = Lla::CustomDomains::ChallengeResolver.resolve(
      host: request.host,
      challenge_id: permitted_params[:id]
    )
    return head :not_found if body.blank?

    render plain: body, status: :ok
  end

  private

  def permitted_params
    params.permit(:id)
  end
end
