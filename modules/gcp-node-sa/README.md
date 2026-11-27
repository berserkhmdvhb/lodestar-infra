# gcp-node-sa

The GKE node service account and its minimal project roles. By default one binding,
`roles/container.defaultNodeServiceAccount`; with `use_default_node_role = false` the four classic
roles (log writer, metric writer, monitoring viewer, resource metadata writer). Never editor or
owner. Codifies guide step 7.

Inputs: `project_id` (required), `account_id`, `display_name`, `use_default_node_role`.
Outputs: `email`.
