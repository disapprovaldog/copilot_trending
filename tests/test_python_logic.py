import sys
import os
import pytest
from datetime import datetime, timezone, timedelta

sys.path.insert(0, os.path.dirname(__file__))
from compute_helper import biz_hours, parse_iso, compute_usage

UTC = timezone.utc


def dt(year, month, day, hour=0, minute=0):
    return datetime(year, month, day, hour, minute, tzinfo=UTC)


class TestBizHours:
    def test_equal_times_returns_zero(self):
        assert biz_hours(dt(2024, 1, 1), dt(2024, 1, 1)) == 0.0

    def test_b_before_a_returns_zero(self):
        assert biz_hours(dt(2024, 1, 2), dt(2024, 1, 1)) == 0.0

    def test_full_business_day(self):
        # 2024-01-01 is a Monday
        assert biz_hours(dt(2024, 1, 1, 8), dt(2024, 1, 1, 17)) == 9.0

    def test_partial_morning(self):
        assert biz_hours(dt(2024, 1, 1, 8), dt(2024, 1, 1, 12)) == 4.0

    def test_before_open_contributes_nothing(self):
        assert biz_hours(dt(2024, 1, 1, 6), dt(2024, 1, 1, 7)) == 0.0

    def test_after_close_contributes_nothing(self):
        assert biz_hours(dt(2024, 1, 1, 18), dt(2024, 1, 1, 20)) == 0.0

    def test_spans_open_boundary(self):
        assert biz_hours(dt(2024, 1, 1, 6), dt(2024, 1, 1, 10)) == 2.0

    def test_spans_close_boundary(self):
        assert biz_hours(dt(2024, 1, 1, 14), dt(2024, 1, 1, 20)) == 3.0

    def test_weekend_skipped(self):
        # 2024-01-06 = Saturday, 2024-01-07 = Sunday
        assert biz_hours(dt(2024, 1, 6, 8), dt(2024, 1, 7, 17)) == 0.0

    def test_full_work_week(self):
        # Mon 08:00 through Fri 17:00 = 5 * 9 = 45 h
        assert biz_hours(dt(2024, 1, 1, 8), dt(2024, 1, 5, 17)) == 45.0

    def test_crosses_weekend(self):
        # Fri 08:00 → Mon 17:00: Fri 9 h + Mon 9 h = 18 h (Sat/Sun zero)
        assert biz_hours(dt(2024, 1, 5, 8), dt(2024, 1, 8, 17)) == 18.0

    def test_fractional_hours(self):
        assert biz_hours(dt(2024, 1, 1, 8), dt(2024, 1, 1, 8, 30)) == 0.5


class TestParseIso:
    def test_z_suffix_parses(self):
        result = parse_iso("2024-06-01T00:00:00Z")
        assert result.utcoffset() is not None

    def test_offset_suffix_parses(self):
        result = parse_iso("2024-06-01T12:00:00+05:30")
        assert result.utcoffset() is not None

    def test_strips_whitespace(self):
        result = parse_iso("  2024-06-01T00:00:00Z  ")
        utc = result.astimezone(UTC)
        assert utc.year == 2024 and utc.month == 6

    def test_z_and_plus00_are_same_moment(self):
        a = parse_iso("2024-06-01T12:00:00Z")
        b = parse_iso("2024-06-01T12:00:00+00:00")
        assert a == b


class TestComputeUsage:
    def _quota_raw(self, used=200, entitlement=1000, plan="copilot_enterprise",
                   reset="2024-07-01T00:00:00Z", bucket="premium_interactions"):
        remaining = entitlement - used
        return {
            "copilot_plan": plan,
            "quota_reset_date_utc": reset,
            "quota_snapshots": {
                bucket: {
                    "has_quota": True,
                    "entitlement": entitlement,
                    "remaining": remaining,
                    "percent_remaining": remaining / entitlement * 100.0,
                }
            },
        }

    # mid-month Wednesday mid-morning — biz hours have elapsed
    _NOW = dt(2024, 6, 12, 14)

    def test_green_icon_below_50pct(self):
        raw = self._quota_raw(used=400, entitlement=1000)
        assert "🟢" in compute_usage(raw, self._NOW)["prompt"]

    def test_yellow_icon_50_to_75pct(self):
        raw = self._quota_raw(used=600, entitlement=1000)
        assert "🟡" in compute_usage(raw, self._NOW)["prompt"]

    def test_orange_icon_75_to_90pct(self):
        raw = self._quota_raw(used=800, entitlement=1000)
        assert "🟠" in compute_usage(raw, self._NOW)["prompt"]

    def test_red_icon_at_or_above_90pct(self):
        raw = self._quota_raw(used=900, entitlement=1000)
        assert "🔴" in compute_usage(raw, self._NOW)["prompt"]

    def test_prompt_contains_used_of_entitlement(self):
        raw = self._quota_raw(used=123, entitlement=500)
        assert "123/500" in compute_usage(raw, self._NOW)["prompt"]

    def test_prompt_contains_single_percent(self):
        raw = self._quota_raw(used=600, entitlement=1000)
        prompt = compute_usage(raw, self._NOW)["prompt"]
        assert "60.0%" in prompt
        assert "%%" not in prompt

    def test_projection_shown_mid_month(self):
        raw = self._quota_raw(used=300, entitlement=1000)
        assert "↗" in compute_usage(raw, self._NOW)["prompt"]

    def test_no_projection_before_first_business_hour(self):
        # 2024-06-03 is Monday; 07:00 is before business open at 08:00
        raw = self._quota_raw(used=0, entitlement=1000)
        now = dt(2024, 6, 3, 7)
        assert "↗" not in compute_usage(raw, now)["prompt"]

    def test_detail_contains_plan_name(self):
        raw = self._quota_raw(plan="copilot_enterprise")
        assert "copilot_enterprise" in compute_usage(raw, self._NOW)["detail"]

    def test_detail_contains_rate_line(self):
        raw = self._quota_raw(used=300, entitlement=1000)
        detail = compute_usage(raw, self._NOW)["detail"]
        assert "Rate" in detail
        assert "biz-hr" in detail

    def test_detail_contains_reset_date(self):
        raw = self._quota_raw(reset="2024-07-01T00:00:00Z")
        assert "2024-07-01" in compute_usage(raw, self._NOW)["detail"]

    def test_unlimited_plan_prompt(self):
        raw = {"copilot_plan": "copilot_for_business", "quota_snapshots": {}}
        result = compute_usage(raw, self._NOW)
        assert "♾️" in result["prompt"]
        assert "unlimited" in result["prompt"]

    def test_unlimited_plan_detail(self):
        raw = {"copilot_plan": "copilot_for_business", "quota_snapshots": {}}
        assert "unlimited" in compute_usage(raw, self._NOW)["detail"]

    def test_quota_bucket_priority_premium_over_chat(self):
        raw = {
            "copilot_plan": "enterprise",
            "quota_reset_date_utc": "2024-07-01T00:00:00Z",
            "quota_snapshots": {
                "premium_interactions": {
                    "has_quota": True, "entitlement": 1000,
                    "remaining": 900, "percent_remaining": 90.0,
                },
                "chat": {
                    "has_quota": True, "entitlement": 500,
                    "remaining": 400, "percent_remaining": 80.0,
                },
            },
        }
        # premium_interactions has entitlement=1000; chat has 500 — should pick 1000
        assert "1000" in compute_usage(raw, self._NOW)["prompt"]

    def test_fallback_to_chat_when_premium_has_no_quota(self):
        raw = {
            "copilot_plan": "enterprise",
            "quota_reset_date_utc": "2024-07-01T00:00:00Z",
            "quota_snapshots": {
                "premium_interactions": {"has_quota": False},
                "chat": {
                    "has_quota": True, "entitlement": 500,
                    "remaining": 400, "percent_remaining": 80.0,
                },
            },
        }
        assert "500" in compute_usage(raw, self._NOW)["prompt"]

    def test_fallback_reset_date_uses_first_of_next_month(self):
        raw = {
            "copilot_plan": "enterprise",
            "quota_snapshots": {
                "premium_interactions": {
                    "has_quota": True, "entitlement": 1000,
                    "remaining": 900, "percent_remaining": 90.0,
                }
            },
        }
        # No reset_str — should still produce valid output without crashing
        result = compute_usage(raw, self._NOW)
        assert "100/1000" in result["prompt"]

    def test_december_fallback_wraps_to_january(self):
        raw = {
            "copilot_plan": "enterprise",
            "quota_snapshots": {
                "premium_interactions": {
                    "has_quota": True, "entitlement": 100,
                    "remaining": 90, "percent_remaining": 90.0,
                }
            },
        }
        now = dt(2024, 12, 15, 14)
        result = compute_usage(raw, now)
        # Should not raise and should produce a prompt
        assert "10/100" in result["prompt"]
