output "secret_ids" {
  description = "Map of <env>-<key> to the secret id."
  value       = { for k, s in google_secret_manager_secret.this : k => s.secret_id }
}

output "binding_titles" {
  description = "Condition titles of the conditional secretAccessor bindings."
  value       = concat([for m in google_project_iam_member.app : one(m.condition).title], [for m in google_project_iam_member.db : one(m.condition).title])
}
