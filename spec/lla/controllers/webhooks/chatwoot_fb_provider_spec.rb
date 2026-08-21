require 'rails_helper'

# `valid_verify_token?` trước đây trả về chính chuỗi cấu hình — một giá trị truthy — nên **mọi**
# verify token đều được chấp nhận. Ai cũng đăng ký được webhook Messenger của bản cài đặt này.
RSpec.describe ChatwootFbProvider do
  subject(:provider) { described_class.new }

  before { create(:installation_config, name: 'FB_VERIFY_TOKEN', value: 'token-that-cua-chung-toi') }

  after { GlobalConfig.clear_cache }

  it 'accepts the configured verify token' do
    expect(provider.valid_verify_token?('token-that-cua-chung-toi')).to be(true)
  end

  it 'refuses a token that is not the configured one' do
    expect(provider.valid_verify_token?('token-bia-ra')).to be(false)
  end

  it 'refuses everything when no verify token is configured' do
    InstallationConfig.find_by(name: 'FB_VERIFY_TOKEN').destroy!
    GlobalConfig.clear_cache

    expect(provider.valid_verify_token?('bat-ky')).to be(false)
  end
end
