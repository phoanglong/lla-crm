json.custom_role_id account_user.custom_role_id

if account_user.custom_role.present?
  json.custom_role do
    json.id account_user.custom_role.id
    json.name account_user.custom_role.name
    json.permissions account_user.custom_role.permissions
  end
end
