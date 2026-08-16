# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::QuotaPolicy do
  describe '.billable?' do
    it 'charges customer responses that use the LLA system credential' do
      expect(described_class.billable?(workload: :customer_response, credential_source: :system)).to be true
    end

    it 'does not charge customer responses that use an account-owned hook' do
      expect(described_class.billable?(workload: :customer_response, credential_source: :hook)).to be false
    end

    it 'does not charge internal tasks regardless of credential source' do
      expect(described_class.billable?(workload: :internal, credential_source: :system)).to be false
      expect(described_class.billable?(workload: :internal, credential_source: :hook)).to be false
    end

    it 'fails closed for an unknown credential source on a customer response' do
      expect(described_class.billable?(workload: :customer_response, credential_source: :unknown)).to be true
    end
  end
end
