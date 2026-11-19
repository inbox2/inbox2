//! Cross-language parity: the Rust half of the shared contract in
//! `fixtures/parity/fixtures.json`. The Ruby half lives in
//! `api/spec/services/cross_language_parity_spec.rb` and drives the SAME file.
//! See `fixtures/parity/README.md` for the drift report.
//!
//! `agreed` cases assert the output both engines currently produce — locking
//! behaviour that matches so it can't silently drift. `divergences` cases assert
//! the Rust-specific output (the `rust` column); the Ruby suite asserts its own
//! (`ruby`) column. A change on either side breaks a test and forces the fixture
//! (and the report) to be updated.

use serde_json::Value;

use crate::rules::conditions::{conditions_match, Condition, MessageFields};
use crate::triage::{self, JevMessage, SpaceDef, TriageLabelDef};
use crate::sync::threading::{build_snippet, normalize_subject};

const FIXTURES: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures/parity/fixtures.json"));

fn fixtures() -> Value {
    serde_json::from_str(FIXTURES).expect("fixtures/parity/fixtures.json parses")
}

/// `null` -> `None`, string -> `Some(&str)`.
fn opt(v: &Value) -> Option<&str> {
    v.as_str()
}

#[test]
fn snippet_parity() {
    let f = fixtures();
    let s = &f["snippet"];
    for c in s["agreed"].as_array().unwrap() {
        let got = build_snippet(opt(&c["body_plain"]), opt(&c["body_html"]));
        assert_eq!(got, c["expected"].as_str().unwrap(), "agreed: {}", c["name"]);
    }
    for c in s["divergences"].as_array().unwrap() {
        let got = build_snippet(opt(&c["body_plain"]), opt(&c["body_html"]));
        assert_eq!(got, c["rust"].as_str().unwrap(), "divergence: {} — {}", c["name"], c["note"]);
    }
}

#[test]
fn subject_parity() {
    let f = fixtures();
    let s = &f["subject"];
    for c in s["agreed"].as_array().unwrap() {
        let got = normalize_subject(c["input"].as_str().unwrap());
        assert_eq!(got, c["expected"].as_str().unwrap(), "agreed: {}", c["name"]);
    }
    for c in s["divergences"].as_array().unwrap() {
        let got = normalize_subject(c["input"].as_str().unwrap());
        assert_eq!(got, c["rust"].as_str().unwrap(), "divergence: {} — {}", c["name"], c["note"]);
    }
}

#[test]
fn conditions_parity() {
    let f = fixtures();
    let s = &f["conditions"];
    let m = &s["message"];
    let fields = MessageFields {
        from: m["from"].as_str().unwrap().to_string(),
        to: m["to"].as_str().unwrap().to_string(),
        subject: m["subject"].as_str().unwrap().to_string(),
        body: m["body"].as_str().unwrap().to_string(),
        has_attachment: m["has_attachment"].as_bool().unwrap(),
    };
    let parse = |conds: &Value| -> Vec<Condition> {
        conds
            .as_array()
            .unwrap()
            .iter()
            .map(|c| Condition {
                field: c["field"].as_str().unwrap().to_string(),
                op: c["op"].as_str().unwrap().to_string(),
                value: c["value"].as_str().unwrap_or("").to_string(),
            })
            .collect()
    };
    for c in s["agreed"].as_array().unwrap() {
        let got = conditions_match(&parse(&c["conditions"]), &fields);
        assert_eq!(got, c["expected"].as_bool().unwrap(), "agreed: {}", c["name"]);
    }
    for c in s["divergences"].as_array().unwrap() {
        let got = conditions_match(&parse(&c["conditions"]), &fields);
        assert_eq!(got, c["rust"].as_bool().unwrap(), "divergence: {} — {}", c["name"], c["note"]);
    }
}

/// A JSON tree that keeps object key order (serde_json's `Value` sorts keys
/// without `preserve_order`, and the Jev contract compares key order too).
enum Ordered {
    Scalar(Value),
    Array(Vec<Ordered>),
    Object(Vec<(String, Ordered)>),
}

impl<'de> serde::Deserialize<'de> for Ordered {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = Ordered;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("JSON")
            }
            fn visit_bool<E>(self, v: bool) -> Result<Ordered, E> {
                Ok(Ordered::Scalar(v.into()))
            }
            fn visit_i64<E>(self, v: i64) -> Result<Ordered, E> {
                Ok(Ordered::Scalar(v.into()))
            }
            fn visit_u64<E>(self, v: u64) -> Result<Ordered, E> {
                Ok(Ordered::Scalar(v.into()))
            }
            fn visit_f64<E>(self, v: f64) -> Result<Ordered, E> {
                Ok(Ordered::Scalar(v.into()))
            }
            fn visit_str<E>(self, v: &str) -> Result<Ordered, E> {
                Ok(Ordered::Scalar(v.into()))
            }
            fn visit_unit<E>(self) -> Result<Ordered, E> {
                Ok(Ordered::Scalar(Value::Null))
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut a: A) -> Result<Ordered, A::Error> {
                let mut v = Vec::new();
                while let Some(x) = a.next_element()? {
                    v.push(x);
                }
                Ok(Ordered::Array(v))
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(self, mut a: A) -> Result<Ordered, A::Error> {
                let mut v = Vec::new();
                while let Some(kv) = a.next_entry()? {
                    v.push(kv);
                }
                Ok(Ordered::Object(v))
            }
        }
        d.deserialize_any(V)
    }
}

impl serde::Serialize for Ordered {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Ordered::Scalar(v) => v.serialize(s),
            Ordered::Array(v) => v.serialize(s),
            Ordered::Object(kv) => triage::Ordered(kv.iter().map(|(k, v)| (k.clone(), v)).collect()).serialize(s),
        }
    }
}

impl std::ops::Index<&str> for Ordered {
    type Output = Ordered;
    fn index(&self, key: &str) -> &Ordered {
        match self {
            Ordered::Object(kv) => &kv.iter().find(|(k, _)| k == key).unwrap_or_else(|| panic!("missing {key}")).1,
            _ => panic!("not an object: {key}"),
        }
    }
}

/// Compact JSON, key order as written.
fn compact<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap()
}

#[test]
fn jev_triage_parity() {
    let f = fixtures();
    let j = &f["jev_triage"];
    let ordered: Ordered = serde_json::from_str(FIXTURES).unwrap();
    let oj = &ordered["jev_triage"];

    assert_eq!(j["model"], crate::typesafe::MODEL);
    assert_eq!(j["space_holding_pen"], triage::HOLDING_PEN);
    assert_eq!(j["space_min_probability"], triage::SPACE_MIN_PROBABILITY);
    assert_eq!(j["priority_levels"], serde_json::json!(triage::PRIORITY_LEVELS));
    // The built-in texts are single-sourced on `TriageLabel` and must match Rails.
    let builtins: Vec<Value> = triage::builtin_labels()
        .iter()
        .map(|l| serde_json::json!({"slug": l.slug, "name": l.name, "description": l.description, "not_for": l.not_for}))
        .collect();
    assert_eq!(j["builtin_labels"], Value::Array(builtins));

    let s = &j["state_example"];
    let messages: Vec<JevMessage> = serde_json::from_value(s["messages"].clone()).unwrap();
    let state = triage::jev_state(s["owner"].as_str().unwrap(), s["subject"].as_str().unwrap(), &messages);
    assert_eq!(compact(&state), compact(&oj["state_example"]["expected"]), "state");

    let Ordered::Array(cases) = &oj["agreed"] else { panic!("agreed is an array") };
    for (i, c) in j["agreed"].as_array().unwrap().iter().enumerate() {
        let labels: Vec<TriageLabelDef> = match &c["labels"] {
            Value::String(s) if s == "builtin" => triage::builtin_labels(),
            v => serde_json::from_value(v.clone()).unwrap(),
        };
        let spaces: Vec<SpaceDef> = serde_json::from_value(c["spaces"].clone()).unwrap();
        let got = triage::jev_questions(&labels, &spaces, c["ask_label"].as_bool().unwrap());
        assert_eq!(compact(&got), compact(&cases[i]["expected"]), "agreed: {}", c["name"]);
    }
}

#[test]
fn otp_parity() {
    let f = fixtures();
    for c in f["otp"]["agreed"].as_array().unwrap() {
        let got = crate::otp::detect(opt(&c["subject"]), opt(&c["body_plain"]), opt(&c["body_html"]), opt(&c["snippet"]));
        let got = serde_json::to_value(got).unwrap();
        assert_eq!(got, c["expected"], "agreed: {}", c["name"]);
    }
}

#[test]
fn next_action_parity() {
    let f = fixtures();
    for c in f["next_action"]["agreed"].as_array().unwrap() {
        let day = chrono::NaiveDate::parse_from_str(c["message_date"].as_str().unwrap(), "%Y-%m-%d").ok();
        let got = crate::next_action::extract(opt(&c["label"]), opt(&c["subject"]), c["text"].as_str().unwrap(), day);
        assert_eq!(serde_json::to_value(got).unwrap(), c["expected"], "agreed: {}", c["name"]);
    }
}
