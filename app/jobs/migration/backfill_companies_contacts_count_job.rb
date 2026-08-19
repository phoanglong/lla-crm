class Migration::BackfillCompaniesContactsCountJob < ApplicationJob
  queue_as :async_database_migration

  def perform
    # Companies are an LLA capability; the guard used to name the folder that
    # happened to define them.
    return unless ChatwootApp.lla?

    Company.find_in_batches(batch_size: 100) do |company_batch|
      company_batch.each do |company|
        Company.reset_counters(company.id, :contacts)
      end
    end
  end
end
