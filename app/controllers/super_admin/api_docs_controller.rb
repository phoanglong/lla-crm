class SuperAdmin::ApiDocsController < SuperAdmin::ApplicationController
  def show; end

  def schema
    response.headers['Cache-Control'] = 'private, no-store'
    send_file Rails.root.join('swagger/swagger.json'), type: 'application/json', disposition: 'inline'
  end
end
