# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountUser, type: :model do
  describe '#permissions' do
    it 'returns domain permissions and the custom role marker' do
      account = create(:account)
      custom_role = create(:custom_role, account: account, permissions: ['contact_manage'])
      account_user = create(:account_user, account: account, custom_role: custom_role)

      expect(account_user.permissions).to eq(%w[contact_manage custom_role])
    end

    it 'keeps the custom role marker when the role has no domain permissions' do
      account = create(:account)
      custom_role = create(:custom_role, account: account, permissions: [])
      account_user = create(:account_user, account: account, custom_role: custom_role)

      expect(account_user.permissions).to eq(['custom_role'])
    end

    it 'keeps the default role permission when no custom role is assigned' do
      account_user = create(:account_user, role: :agent)

      expect(account_user.permissions).to eq(['agent'])
    end
  end

  describe 'custom role tenant boundary' do
    it 'rejects a custom role from another account' do
      account_user = build(:account_user)
      other_account_role = create(:custom_role, account: create(:account))

      account_user.custom_role = other_account_role

      expect(account_user).not_to be_valid
      expect(account_user.errors[:custom_role]).to include('must belong to the same account as the account user')
    end
  end
end
