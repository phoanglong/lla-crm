# frozen_string_literal: true

require 'rails_helper'

# The same shape of bug as the changelog card, on a different axis: a gate that asks
# which *edition* this is instead of whether the capability is present.
#
# `ChatwootApp.voice_calls?` is `enterprise? || lla?`, so the voice-call routes exist
# on this product. The dashboard hid the Calls entry behind
# `isOnChatwootCloud || isEnterprise` — both false here, because `enterprise/` was
# deleted — so the server served an API the interface offered no way to reach. The
# screen was accessible only by typing its URL, which is also why nobody noticed its
# translations were missing.
RSpec.describe 'the voice-call capability', type: :request do
  it 'is on, and does not depend on the enterprise edition' do
    expect(ChatwootApp.enterprise?).to be(false)
    expect(ChatwootApp.voice_calls?).to be(true)
  end

  it 'routes the calls index it advertises' do
    expect(Rails.application.routes.recognize_path('/api/v1/accounts/1/calls', method: :get))
      .to include(controller: 'api/v1/accounts/calls', action: 'index')
  end

  # The assertion that matters: the browser is told the capability, so the sidebar can
  # gate on it rather than on the edition.
  it 'is handed to the dashboard, matching what the server decided' do
    get '/app'

    expect(response).to have_http_status(:success)
    expect(response.body).to include("voiceCallsEnabled: '#{ChatwootApp.voice_calls?}'")
  end

  it 'is not gated on the edition flag the dashboard also receives' do
    get '/app'

    expect(response.body).to include("isEnterprise: 'false'")
    expect(response.body).to include("voiceCallsEnabled: 'true'")
  end
end
