//! Wall-clock readings. A clock set before 1970 reads as 0 rather than failing.

use std::time::{SystemTime, UNIX_EPOCH};

fn since_epoch() -> std::time::Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
}

/// Seconds since the Unix epoch.
pub fn now_secs() -> u64 {
    since_epoch().as_secs()
}

/// Milliseconds since the Unix epoch.
pub fn now_millis() -> u128 {
    since_epoch().as_millis()
}

/// Nanoseconds since the Unix epoch (for unique file-name tokens).
pub fn now_nanos() -> u128 {
    since_epoch().as_nanos()
}

/// Days since 1970-01-01 of a date of the proleptic Gregorian calendar.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month = i64::from(month);
    let day_of_year =
        (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// The date of a count of days since 1970-01-01.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let mp = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (year_of_era + era * 400 + i64::from(month <= 2), month, day)
}

/// Seconds since the epoch of a UTC timestamp as tools write it: `2026-11-13T18:05:00Z`, with
/// optional fractions, `UTC` or `+00:00` instead of `Z`. Anything else (another offset) is `None`.
pub fn parse_utc(text: &str) -> Option<u64> {
    let text = text.trim();
    let (date, rest) = text.split_once('T')?;
    let mut parts = date.split('-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: u32 = parts.next()?.parse().ok()?;
    let day: u32 = parts.next()?.parse().ok()?;
    let clock = rest
        .strip_suffix('Z')
        .or_else(|| rest.strip_suffix("UTC"))
        .or_else(|| rest.strip_suffix("+00:00"))?;
    let clock = clock.split('.').next()?;
    let mut fields = clock.split(':');
    let hour: u64 = fields.next()?.parse().ok()?;
    let minute: u64 = fields.next()?.parse().ok()?;
    let second: u64 = fields.next().unwrap_or("0").parse().ok()?;
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let days = u64::try_from(days_from_civil(year, month, day)).ok()?;
    Some(days * 86_400 + hour * 3600 + minute * 60 + second)
}

/// `YYYYMMDD-HHMMSS` in UTC, for file names that sort by date.
pub fn utc_stamp(secs: u64) -> String {
    let (year, month, day) = civil_from_days((secs / 86_400) as i64);
    let rest = secs % 86_400;
    format!(
        "{year:04}{month:02}{day:02}-{:02}{:02}{:02}",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_timestamps_parse_and_print() {
        assert_eq!(parse_utc("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc("2026-11-13T18:05:09Z"), Some(1_794_593_109));
        assert_eq!(parse_utc("2026-11-13T18:05:09UTC"), Some(1_794_593_109));
        assert_eq!(
            parse_utc("2026-11-13T18:05:09.123+00:00"),
            Some(1_794_593_109)
        );
        assert_eq!(parse_utc("2024-02-29T00:00:00Z"), Some(1_709_164_800));
        assert_eq!(parse_utc("2026-11-13T18:05:09-03:00"), None);
        assert_eq!(parse_utc("mañana"), None);
        assert_eq!(utc_stamp(1_794_593_109), "20261113-180509");
        assert_eq!(utc_stamp(1_709_164_800), "20240229-000000");
    }

    #[test]
    fn units_agree() {
        let secs = now_secs();
        assert!(secs > 1_700_000_000);
        assert!(now_millis() / 1000 >= secs as u128);
        assert!(now_nanos() / 1_000_000 >= now_millis() - 1000);
    }
}
