json.id resource.id
json.action resource.action
json.auditable_id resource.auditable_id
json.auditable_type resource.auditable_type
json.audited_changes resource.audited_changes
json.associated_id resource.associated_id
json.associated_type resource.associated_type
json.user_id resource.user_id
json.username resource.username
json.remote_address resource.remote_address
# Unix seconds, not an ISO string. `auditlogs/Index.vue` renders this through
# `messageTimestamp`, which is `fromUnixTime` — handed a string it produces an
# Invalid Date and `format` throws `RangeError: Invalid time value`, taking the
# whole table render with it.
json.created_at resource.created_at.to_i

# Giao diện đọc auditLogItem.auditable?.user_id để phân biệt "sửa chính mình" và
# "sửa người khác" — xem handleAccountUserUpdate trong auditlogHelper.js.
if resource.auditable.respond_to?(:user_id)
  json.auditable do
    json.id resource.auditable.id
    json.user_id resource.auditable.user_id
  end
end
