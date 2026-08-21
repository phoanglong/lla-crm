# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

require_relative 'config/application'
# LLA rake tasks.
lla_tasks_path = Rails.root.join('lla/rails/tasks_railtie.rb').to_s
require lla_tasks_path if File.exist?(lla_tasks_path)

Rails.application.load_tasks
