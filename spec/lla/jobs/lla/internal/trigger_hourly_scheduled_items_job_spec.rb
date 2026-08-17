# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Internal::TriggerHourlyScheduledItemsJob, type: :job do
  include ActiveJob::TestHelper

  it 'schedules LLA quota reconciliation through the existing hourly trigger' do
    allow(Channels::Whatsapp::HealthSyncSchedulerJob).to receive(:perform_later)

    expect { described_class.perform_now }.to have_enqueued_job(Lla::Captain::QuotaReconciliationJob).once
  end

  it 'schedules knowledge generation recovery through the existing hourly trigger' do
    allow(Channels::Whatsapp::HealthSyncSchedulerJob).to receive(:perform_later)

    expect { described_class.perform_now }.to have_enqueued_job(Lla::Knowledge::GenerationReconciliationJob).once
  end
end
