# gcp-network

Custom-mode regional VPC, a subnet with Private Google Access and `pods` / `services` secondary
ranges, a Cloud Router and Cloud NAT (all subnets, automatic IPs, error logging, endpoint-independent mapping off). An optional
proxy-only subnet (`enable_proxy_only_subnet`) serves the previews' internal Gateway. Codifies guide
step 6. Defaults equal the hand-built values, except VPC flow logs on the node subnet (task L1.4: 10-minute
aggregation, 10 percent sampling, all metadata; `enable_flow_logs = false` removes them).

Inputs: `project_id` (required), `region`, `network_name`, `subnet_name`, `subnet_cidr`, `pods_cidr`,
`services_cidr`, `router_name`, `nat_name`, `enable_proxy_only_subnet`, `proxy_only_subnet_name`,
`proxy_only_cidr`, `enable_flow_logs`, `flow_log_aggregation_interval`, `flow_log_sampling`,
`flow_log_metadata`.
Outputs: `network_self_link`, `network_name`, `subnet_self_link`, `subnet_name`, `pods_range_name`,
`services_range_name`.
