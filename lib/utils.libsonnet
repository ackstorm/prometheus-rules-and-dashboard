{
  // Define a filter function to remove unwanted alerts
  filterAlerts(ignore_alerts):: {
    prometheusAlerts+:: {
      groups: std.map(
        function(group)
          group {
            rules: std.filter(
              function(rule)
                if std.objectHas(rule, 'alert') then
                  std.count(ignore_alerts, rule.alert) == 0
                else
                  true,
              group.rules
            ),
          },
        super.groups
      ),
    },
  },

  // Define a filter function to remove unwanted groups
  filterGroups(ignore_groups):: {
    prometheusRules+:: {
      groups: std.filter(
        function(group)
          std.count(ignore_groups, group.name) == 0,
        super.groups
      ),
    },
  },
  // Update expressions for either alerts or record definitions.
  updateExpressions(expr_overrides):: {
    prometheus+:: {
      groups: std.map(
        function(group)
          group {
            rules: std.map(
              function(rule)
                if std.objectHas(expr_overrides, rule.record) then
                  rule {
                    expr: expr_overrides[rule.record],
                  }
                else
                  rule,
              group.rules
            ),
          },
        super.groups
      ),
    },
  },
}
