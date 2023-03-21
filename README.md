# Monitoring Mixins

Builds base prometheus mixin from multiple repos (alerts and dashboards)

## Adding new mixin

0. Install [required software](#requirements)
1. Add new mixin to [mixins.json](mixins.json) file
2. Run `generate.sh`
3. Run `push.sh` to publish changes to git

## Requirements

- yq
- git
- jsonnet

