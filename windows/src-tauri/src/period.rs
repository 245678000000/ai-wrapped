//! The span a report covers, same rules as the macOS app. Weeks run Monday to Sunday.

use crate::model::ScanResult;
use crate::report::{date_of, day_of, key_of, DayKey};
use chrono::{Datelike, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Period {
    Year { year: i32 },
    All,
    ThisWeek,
    LastWeek,
    ThisMonth,
}

pub const WEEKDAYS: [&str; 7] = ["一", "二", "三", "四", "五", "六", "日"];

pub fn weekday_index(d: DayKey) -> usize {
    date_of(d).weekday().num_days_from_monday() as usize
}
fn monday_of(d: DayKey) -> DayKey {
    d - weekday_index(d) as i64
}
fn first_of_month(d: DayKey) -> DayKey {
    let x = date_of(d);
    key_of(NaiveDate::from_ymd_opt(x.year(), x.month(), 1).unwrap())
}
fn days_in_month(d: DayKey) -> i64 {
    let x = date_of(d);
    let (y, m) = if x.month() == 12 { (x.year() + 1, 1) } else { (x.year(), x.month() + 1) };
    key_of(NaiveDate::from_ymd_opt(y, m, 1).unwrap()) - first_of_month(d)
}

impl Period {
    pub fn is_short(&self) -> bool {
        matches!(self, Period::ThisWeek | Period::LastWeek | Period::ThisMonth)
    }

    pub fn is_week(&self) -> bool {
        matches!(self, Period::ThisWeek | Period::LastWeek)
    }

    pub fn year(&self) -> Option<i32> {
        match self {
            Period::Year { year } => Some(*year),
            _ => None,
        }
    }

    /// Inclusive range of local days; None means all time.
    pub fn range(&self, today: DayKey) -> Option<(DayKey, DayKey)> {
        match self {
            Period::Year { year } => Some((
                key_of(NaiveDate::from_ymd_opt(*year, 1, 1).unwrap()),
                key_of(NaiveDate::from_ymd_opt(*year, 12, 31).unwrap()),
            )),
            Period::All => None,
            Period::ThisWeek => {
                let m = monday_of(today);
                Some((m, m + 6))
            }
            Period::LastWeek => {
                let m = monday_of(today) - 7;
                Some((m, m + 6))
            }
            Period::ThisMonth => {
                let f = first_of_month(today);
                Some((f, f + days_in_month(f) - 1))
            }
        }
    }

    /// What to compare against. An unfinished week or month is compared with the same number of
    /// days at the start of the previous one, so a two-day-old week isn't "down 70%".
    pub fn comparison(&self, today: DayKey) -> Option<((DayKey, DayKey), &'static str)> {
        match self {
            Period::ThisWeek => {
                let m = monday_of(today);
                let elapsed = today - m;
                Some(((m - 7, m - 7 + elapsed), if elapsed >= 6 { "上周" } else { "上周同期" }))
            }
            Period::LastWeek => {
                let m = monday_of(today) - 7;
                Some(((m - 7, m - 1), "前一周"))
            }
            Period::ThisMonth => {
                let first = first_of_month(today);
                let previous = first_of_month(first - 1);
                let elapsed = (today - first).min(days_in_month(previous) - 1);
                let complete = today - first + 1 >= days_in_month(first);
                Some(((previous, previous + elapsed), if complete { "上月" } else { "上月同期" }))
            }
            Period::Year { .. } | Period::All => None,
        }
    }

    pub fn elapsed_days(&self, today: DayKey) -> Option<i64> {
        if !self.is_short() {
            return None;
        }
        let (lo, hi) = self.range(today)?;
        Some((hi.min(today) - lo + 1).max(0))
    }

    pub fn label(&self) -> String {
        match self {
            Period::Year { year } => format!("{year} 年"),
            Period::All => "全部时间".into(),
            Period::ThisWeek => "本周".into(),
            Period::LastWeek => "上周".into(),
            Period::ThisMonth => "本月".into(),
        }
    }

    pub fn report_name(&self) -> &'static str {
        match self {
            Period::Year { .. } | Period::All => "AI 年度报告",
            Period::ThisWeek | Period::LastWeek => "AI 周报",
            Period::ThisMonth => "AI 月报",
        }
    }

    /// Lead-in for sentences: "这一年，你和 AI…".
    pub fn phrase(&self) -> &'static str {
        match self {
            Period::Year { .. } => "这一年",
            Period::All => "到目前为止",
            Period::ThisWeek => "这一周",
            Period::LastWeek => "上周",
            Period::ThisMonth => "这个月",
        }
    }

    /// "第 44 周" / "10 月" / "2026".
    pub fn badge(&self, today: DayKey) -> String {
        match self {
            Period::Year { year } => year.to_string(),
            Period::All => "ALL TIME".into(),
            Period::ThisWeek | Period::LastWeek => format!("第 {} 周", date_of(self.range(today).unwrap().0).iso_week().week()),
            Period::ThisMonth => format!("{} 月", date_of(today).month()),
        }
    }

    /// "10.26 – 11.01" for weeks, "2026.10" for a month.
    pub fn range_text(&self, today: DayKey) -> String {
        match (self, self.range(today)) {
            (Period::Year { year }, _) => year.to_string(),
            (Period::ThisMonth, Some((lo, _))) => {
                let a = date_of(lo);
                format!("{}.{:02}", a.year(), a.month())
            }
            (_, Some((lo, hi))) => {
                let (a, b) = (date_of(lo), date_of(hi));
                format!("{}.{:02} – {}.{:02}", a.month(), a.day(), b.month(), b.day())
            }
            _ => "ALL TIME".into(),
        }
    }

    pub fn file_tag(&self, today: DayKey) -> String {
        match self {
            Period::Year { year } => year.to_string(),
            Period::All => "全部".into(),
            Period::ThisWeek | Period::LastWeek => format!("W{}", date_of(self.range(today).unwrap().0).iso_week().week()),
            Period::ThisMonth => self.range_text(today),
        }
    }

    /// Says exactly what the change arrows compare against.
    pub fn basis(&self, today: DayKey, comparison_label: &str) -> String {
        let elapsed = self.elapsed_days(today).unwrap_or(0);
        let total = self.range(today).map(|(lo, hi)| hi - lo + 1).unwrap_or(0);
        match self {
            Period::ThisWeek if elapsed == 1 => "和上周一相比".into(),
            Period::ThisWeek if elapsed < 7 => format!("和上周同期（周一到周{}）相比", WEEKDAYS[(elapsed - 1) as usize]),
            Period::ThisMonth if elapsed < total => format!("和上月同期（1–{elapsed} 日）相比"),
            _ => format!("和{comparison_label}相比"),
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Period::Year { .. } => "year",
            Period::All => "all",
            Period::ThisWeek => "thisWeek",
            Period::LastWeek => "lastWeek",
            Period::ThisMonth => "thisMonth",
        }
    }
}

/// Headline numbers of a span, for "比上周 ↑ 32%".
#[derive(Serialize, Clone, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PeriodTotals {
    pub tokens: i64,
    pub sessions: usize,
    pub prompts: usize,
    pub active_days: usize,
}

pub fn totals(scan: &ScanResult, (lo, hi): (DayKey, DayKey)) -> PeriodTotals {
    let inside = |d: DayKey| d >= lo && d <= hi;
    let mut t = PeriodTotals::default();
    let mut sessions: HashSet<&str> = HashSet::new();
    let mut days: HashSet<DayKey> = HashSet::new();
    for u in &scan.usage {
        let d = day_of(u.time);
        if inside(d) {
            t.tokens += u.tokens.total();
            days.insert(d);
        }
    }
    for p in &scan.prompts {
        let d = day_of(p.time);
        if inside(d) {
            t.prompts += 1;
            sessions.insert(&p.session);
            days.insert(d);
        }
    }
    for (key, info) in &scan.sessions {
        if let Some(d) = info.start.map(day_of).filter(|d| inside(*d)) {
            sessions.insert(key);
            days.insert(d);
        }
    }
    t.sessions = sessions.len();
    t.active_days = days.len();
    t
}

/// Everything the page needs to describe the period, computed once here.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeriodInfo {
    pub kind: &'static str,
    pub label: String,
    pub report_name: &'static str,
    pub phrase: &'static str,
    pub badge: String,
    pub range_text: String,
    pub file_tag: String,
    pub is_short: bool,
    pub is_week: bool,
    pub elapsed_days: Option<i64>,
    pub total_days: Option<i64>,
    pub comparison_label: String,
    pub basis: String,
}

impl PeriodInfo {
    pub fn new(p: &Period, today: DayKey) -> Self {
        let comparison_label = p.comparison(today).map(|c| c.1).unwrap_or("").to_string();
        PeriodInfo {
            kind: p.kind(),
            label: p.label(),
            report_name: p.report_name(),
            phrase: p.phrase(),
            badge: p.badge(today),
            range_text: p.range_text(today),
            file_tag: p.file_tag(today),
            is_short: p.is_short(),
            is_week: p.is_week(),
            elapsed_days: p.elapsed_days(today),
            total_days: p.range(today).filter(|_| p.is_short()).map(|(lo, hi)| hi - lo + 1),
            basis: p.basis(today, &comparison_label),
            comparison_label,
        }
    }
}
