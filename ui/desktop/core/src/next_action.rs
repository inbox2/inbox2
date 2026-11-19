//! Next-action fields for a Lore item (docs/Triage.md "Next-action fields"): a
//! due date and an amount + currency, pulled from the subject and the newest
//! message's text with plain rules — no model call.
//!
//! The Ruby twin is `api/app/services/next_action_extractor.rb`; both are held
//! to the `next_action` cases in `fixtures/parity/fixtures.json`, so change
//! them together.
//!
//! ponytail: regex heuristics, English + Dutch cue words. Misses an amount or a
//! date phrased without a cue; move to a Jev extraction if that matters.

use chrono::{Datelike, Duration, NaiveDate};
use regex::Regex;
use serde::Serialize;
use std::sync::OnceLock;

use crate::triage::TriageLabel;

/// Labels whose threads carry next-action fields; every other label gets none.
pub const LABELS: [TriageLabel; 5] = [
    TriageLabel::PaymentDue,
    TriageLabel::ActionRequired,
    TriageLabel::NeedsApproval,
    TriageLabel::Scheduling,
    TriageLabel::NeedsAnswer,
];
const MAX_CHARS: usize = 8000;
/// Chars before an amount searched for an amount cue.
const CUE_WINDOW: usize = 40;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct NextAction {
    /// `YYYY-MM-DD`.
    pub due_on: Option<String>,
    pub amount_cents: Option<i64>,
    /// ISO 4217.
    pub currency: Option<String>,
}

macro_rules! re {
    ($pat:expr) => {{
        static RE: OnceLock<Regex> = OnceLock::new();
        RE.get_or_init(|| Regex::new(&$pat).expect("next_action regex"))
    }};
}

const NUM: &str = r"[0-9]{1,3}(?:[.,][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?";
const SP: &str = r"[ \t\x{A0}]";
const MONTHS: &[(&str, u32)] = &[
    ("january", 1), ("januari", 1), ("jan", 1), ("february", 2), ("februari", 2), ("feb", 2),
    ("march", 3), ("maart", 3), ("mrt", 3), ("mar", 3), ("april", 4), ("apr", 4),
    ("may", 5), ("mei", 5), ("june", 6), ("juni", 6), ("jun", 6), ("july", 7), ("juli", 7), ("jul", 7),
    ("august", 8), ("augustus", 8), ("aug", 8), ("september", 9), ("sept", 9), ("sep", 9),
    ("october", 10), ("oktober", 10), ("oct", 10), ("okt", 10), ("november", 11), ("nov", 11),
    ("december", 12), ("dec", 12),
];
const FILLER: &str = "date|datum|on|op|the|de|is|of|van|uiterlijk|vóór|voor|\
monday|tuesday|wednesday|thursday|friday|saturday|sunday|\
maandag|dinsdag|woensdag|donderdag|vrijdag|zaterdag|zondag";

fn month_alt() -> String {
    let mut names: Vec<&str> = MONTHS.iter().map(|(m, _)| *m).collect();
    // Longest first so "june" wins over "jun"; equal lengths can't prefix each other.
    names.sort_by_key(|m| std::cmp::Reverse(m.len()));
    format!(r"({})\b\.?", names.join("|"))
}
fn month_num(name: &str) -> u32 {
    let name = name.to_lowercase();
    MONTHS.iter().find(|(m, _)| *m == name).map(|(_, n)| *n).unwrap_or(0)
}

fn money() -> &'static Regex {
    re!(format!(
        r"(HK\$|€|\$|£|\b(?:EUR|USD|GBP|AED|PKR)){SP}?({NUM})|({NUM}){SP}?(€|(?:EUR|USD|GBP|AED|PKR)\b)"
    ))
}
fn amount_cue() -> &'static Regex {
    re!(r"(?i)\b(?:total|totaal|amount due|te betalen|bedrag|balance|due)\b")
}
fn due_cue() -> &'static Regex {
    re!(format!(
        r"(?i)\b(?:due|before|by|deadline|uiterlijk|vóór|voor|vervaldatum)\b(?:[ \t\x{{A0}}:,.]+(?:{FILLER})\b)*[ \t\x{{A0}}:,.]*"
    ))
}
fn iso() -> &'static Regex {
    re!(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})")
}
fn dmy() -> &'static Regex {
    re!(r"^([0-9]{1,2})[-/.]([0-9]{1,2})[-/.]([0-9]{4})")
}
fn d_month() -> &'static Regex {
    re!(format!(r"(?i)^([0-9]{{1,2}})(?:st|nd|rd|th)?{SP}+{}(?:[ \t\x{{A0}},]+([0-9]{{4}}))?", month_alt()))
}
fn month_d() -> &'static Regex {
    re!(format!(r"(?i)^{}{SP}+([0-9]{{1,2}})(?:st|nd|rd|th)?(?:,?{SP}+([0-9]{{4}}))?", month_alt()))
}
fn relative() -> &'static Regex {
    re!(format!(r"(?i)\b(?:within|binnen){SP}+([0-9]{{1,3}}){SP}+(?:days?|dagen|dag)\b"))
}

/// `message_date` is the newest message's UTC day.
pub fn extract(label: Option<&str>, subject: Option<&str>, text: &str, message_date: Option<NaiveDate>) -> NextAction {
    let (Some(label), Some(day)) = (label.and_then(TriageLabel::from_str), message_date) else {
        return NextAction::default();
    };
    if !LABELS.contains(&label) {
        return NextAction::default();
    }
    let hay: String = format!("{}\n{}", subject.unwrap_or(""), text).chars().take(MAX_CHARS).collect();
    let (amount_cents, currency) = match amount(&hay) {
        Some((c, cur)) => (Some(c), Some(cur)),
        None => (None, None),
    };
    NextAction { due_on: due_on(&hay, day).map(|d| d.format("%Y-%m-%d").to_string()), amount_cents, currency }
}

fn amount(hay: &str) -> Option<(i64, String)> {
    let found: Vec<(i64, String, usize)> = money()
        .captures_iter(hay)
        .map(|m| {
            let sym = m.get(1).or(m.get(4)).map_or("", |g| g.as_str());
            let cur = match sym {
                "€" => "EUR",
                "$" => "USD",
                "£" => "GBP",
                "HK$" => "HKD",
                other => other,
            };
            let num = m.get(2).or(m.get(3)).map_or("", |g| g.as_str());
            (cents(num), cur.to_string(), m.get(0).unwrap().start())
        })
        .collect();
    let cued = found.iter().find(|(_, _, at)| {
        let before = &hay[..*at];
        let from = before.char_indices().rev().nth(CUE_WINDOW - 1).map_or(0, |(i, _)| i);
        amount_cue().is_match(&before[from..])
    });
    // Else the largest, the first on a tie.
    let pick = cued.or_else(|| found.iter().fold(None, |best: Option<&(i64, String, usize)>, f| match best {
        Some(b) if f.0 <= b.0 => Some(b),
        _ => Some(f),
    }))?;
    Some((pick.0, pick.1.clone()))
}

/// "1.234,56" / "1,234.56" / "386,00" / "1.234": the last separator is the
/// decimal point when 1-2 digits follow it, else a thousands separator.
fn cents(num: &str) -> i64 {
    let strip = |s: &str| s.chars().filter(|c| c.is_ascii_digit()).collect::<String>().parse::<i64>().unwrap_or(0);
    match num.rfind(['.', ',']) {
        Some(last) if num.len() - last - 1 <= 2 => {
            let frac = format!("{:0<2}", &num[last + 1..]);
            strip(&num[..last]) * 100 + frac.parse::<i64>().unwrap_or(0)
        }
        _ => strip(num) * 100,
    }
}

fn due_on(hay: &str, day: NaiveDate) -> Option<NaiveDate> {
    for m in due_cue().find_iter(hay) {
        if let Some(d) = parse_date(&hay[m.end()..], day) {
            return Some(d);
        }
    }
    let n: i64 = relative().captures(hay)?.get(1)?.as_str().parse().ok()?;
    Some(day + Duration::days(n))
}

fn parse_date(rest: &str, day: NaiveDate) -> Option<NaiveDate> {
    let n = |c: &regex::Captures, i: usize| c.get(i).and_then(|g| g.as_str().parse::<i32>().ok());
    if let Some(c) = iso().captures(rest) {
        on_or_after(n(&c, 1)?, n(&c, 2)? as u32, n(&c, 3)? as u32, day)
    } else if let Some(c) = dmy().captures(rest) {
        on_or_after(n(&c, 3)?, n(&c, 2)? as u32, n(&c, 1)? as u32, day)
    } else if let Some(c) = d_month().captures(rest) {
        with_year(n(&c, 3), month_num(c.get(2)?.as_str()), n(&c, 1)? as u32, day)
    } else if let Some(c) = month_d().captures(rest) {
        with_year(n(&c, 3), month_num(c.get(1)?.as_str()), n(&c, 2)? as u32, day)
    } else {
        None
    }
}

/// No year: this year's date, or next year's when that has already passed.
fn with_year(year: Option<i32>, month: u32, d: u32, day: NaiveDate) -> Option<NaiveDate> {
    match year {
        Some(y) => on_or_after(y, month, d, day),
        None => on_or_after(day.year(), month, d, day).or_else(|| on_or_after(day.year() + 1, month, d, day)),
    }
}

fn on_or_after(year: i32, month: u32, d: u32, day: NaiveDate) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(year, month, d).filter(|date| *date >= day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(label: &str, subject: &str, text: &str) -> NextAction {
        extract(Some(label), Some(subject), text, NaiveDate::from_ymd_opt(2026, 10, 20))
    }

    #[test]
    fn dutch_invoice() {
        let r = run("payment_due", "Factuur", "Het bedrag van € 386,00 dient uiterlijk 24 oktober 2026 te worden voldaan.");
        assert_eq!(r.amount_cents, Some(38600));
        assert_eq!(r.currency.as_deref(), Some("EUR"));
        assert_eq!(r.due_on.as_deref(), Some("2026-10-24"));
    }

    #[test]
    fn cued_total_beats_line_items() {
        let r = run("payment_due", "Invoice", "Subtotal €300.00, VAT €86.00, Total €386.00");
        assert_eq!(r.amount_cents, Some(38600));
    }

    #[test]
    fn number_formats() {
        assert_eq!(cents("1.234,56"), 123456);
        assert_eq!(cents("1,234.56"), 123456);
        assert_eq!(cents("1.234"), 123400);
        assert_eq!(cents("1,5"), 150);
        assert_eq!(cents("386"), 38600);
    }

    #[test]
    fn relative_and_past_dates() {
        assert_eq!(run("payment_due", "x", "pay within 14 days").due_on.as_deref(), Some("2026-11-03"));
        assert_eq!(run("payment_due", "x", "due 2026-01-05").due_on, None);
        // No year, already passed this year → next year.
        assert_eq!(run("scheduling", "x", "before 3 March").due_on.as_deref(), Some("2027-03-03"));
    }

    #[test]
    fn other_labels_get_nothing() {
        assert_eq!(run("fyi", "x", "Total €5 due 2026-10-25"), NextAction::default());
        assert_eq!(extract(None, None, "Total €5", NaiveDate::from_ymd_opt(2026, 10, 20)), NextAction::default());
    }
}
