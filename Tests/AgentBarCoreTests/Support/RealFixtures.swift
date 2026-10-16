/// Real API responses captured 2026-07-03 (anonymized). Keep byte-shape
/// faithful: these guard against regressions when the live schema drifts.
enum RealFixtures {
    static let claudeExperimental = """
    {
      "five_hour": {"utilization": 29.0, "resets_at": "2026-07-03T14:20:00.251883+00:00"},
      "seven_day": {"utilization": 71.0, "resets_at": "2026-07-05T08:00:00.251906+00:00"},
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                      "utilization": null, "currency": null},
      "limits": [
        {"kind": "session", "group": "session", "percent": 29, "severity": "normal",
         "resets_at": "2026-07-03T14:20:00.251883+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 71, "severity": "normal",
         "resets_at": "2026-07-05T08:00:00.251906+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 81, "severity": "warning",
         "resets_at": "2026-07-05T08:00:00.252313+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": true}
      ],
      "spend": {
        "used": {"amount_minor": 0, "currency": "USD", "exponent": 2},
        "limit": null, "percent": 0, "severity": "normal", "enabled": false,
        "disabled_reason": null, "cap": null, "balance": null,
        "can_purchase_credits": false, "can_toggle": false
      }
    }
    """

    /// Pre-limits response shape (fallback path).
    static let claudeLegacyShape = """
    {"five_hour":{"utilization":82.0,"resets_at":"2026-07-03T14:32:00.000Z"},
     "seven_day":{"utilization":41.5,"resets_at":"2026-07-07T00:00:00Z"},
     "extra_usage":{"is_enabled":false}}
    """

    static let codexProlite = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "allowed": true, "limit_reached": false,
        "primary_window": {"used_percent": 92, "limit_window_seconds": 18000,
                           "reset_after_seconds": 5222, "reset_at": 1783084225},
        "secondary_window": {"used_percent": 41, "limit_window_seconds": 604800,
                             "reset_after_seconds": 538720, "reset_at": 1783617722}
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": [
        {"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
         "rate_limit": {
           "allowed": true, "limit_reached": false,
           "primary_window": {"used_percent": 0, "limit_window_seconds": 18000,
                              "reset_after_seconds": 18000, "reset_at": 1783097003},
           "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800,
                                "reset_after_seconds": 604800, "reset_at": 1783683803}
         }}
      ],
      "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false,
                  "balance": "0", "approx_local_messages": [0, 0], "approx_cloud_messages": [0, 0]},
      "spend_control": {"reached": false, "individual_limit": null},
      "rate_limit_reached_type": null, "promo": null
    }
    """
}
