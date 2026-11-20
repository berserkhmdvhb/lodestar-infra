# The plugin binary is installed by `make tools` from a checksum-verified release into
# $TFLINT_PLUGIN_DIR (set by the Makefile), so `tflint --init` finds it and downloads nothing.
# Keep version in step with tools/pins.tsv.
plugin "google" {
  enabled = true
  version = "0.41.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
