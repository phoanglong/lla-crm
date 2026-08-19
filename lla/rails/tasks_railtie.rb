# frozen_string_literal: true

# Loads LLA rake tasks the same way the enterprise ones are loaded, so an LLA
# operation is available in every mode rather than only when `enterprise/` happens
# to be present on disk.
class LlaTasksRailtie < Rails::Railtie
  rake_tasks do
    Dir.glob(Rails.root.join('lla/rails/lib/tasks/**/*.rake')).each { |file| load file }
  end
end
