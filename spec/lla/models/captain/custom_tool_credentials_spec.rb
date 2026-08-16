require 'rails_helper'

RSpec.describe Captain::CustomTool, type: :model do
  before do
    skip('encryption keys missing; run this spec with Active Record encryption enabled') unless Chatwoot.encryption_configured?
  end

  it 'encrypts custom-tool credentials at rest and clears the legacy JSON column' do
    token = 'lla-test-token-not-a-real-secret'
    tool = create(:captain_custom_tool, auth_type: 'bearer', auth_config: { token: token })

    raw_ciphertext = tool.reload.read_attribute_before_type_cast(:auth_config_ciphertext).to_s

    expect(raw_ciphertext).to be_present
    expect(raw_ciphertext).not_to include(token)
    expect(tool.read_attribute(:auth_config)).to eq({})
    expect(tool.auth_config).to eq('token' => token)
    expect(tool.auth_configured?).to be(true)
    expect(tool.encrypted_attribute?(:auth_config_ciphertext)).to be(true)
  end

  it 'refuses to persist credentials when encryption is not configured' do
    allow(Chatwoot).to receive(:encryption_configured?).and_return(false)
    tool = build(:captain_custom_tool, auth_type: 'bearer', auth_config: { token: 'dummy-token' })

    expect(tool).not_to be_valid
    expect(tool.errors[:auth_config]).to include('requires Active Record encryption keys')
  end
end
