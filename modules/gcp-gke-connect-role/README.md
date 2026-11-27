# gcp-gke-connect-role

The custom role `gkeDnsConnect` (get and connect only), created once per project. Use it when several
`gcp-github-wif` calls share a project: pass `role_name` as their `deployer_cluster_role` and leave
`create_custom_connect_role` off. The permissions equal the role `gcp-github-wif` creates itself (a test compares them).

Inputs: `project_id`. Outputs: `role_name`.
