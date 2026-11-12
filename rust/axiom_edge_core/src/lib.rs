//! Engine-agnostic deterministic checks and portable result records.
//! The Flutter application uses Dart checks in v0.1; bridging this crate is planned
//! after the mobile inference adapters are stable.

use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AssertionKind {
    Exact,
    Contains,
    Regex,
    JsonValid,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Assertion {
    pub kind: AssertionKind,
    #[serde(default)]
    pub value: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvalCase {
    pub id: String,
    pub prompt: String,
    pub assertion: Assertion,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvalSuite {
    pub suite: String,
    pub cases: Vec<EvalCase>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvalVerdict {
    pub case_id: String,
    pub passed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EvalError {
    MissingExpected,
    InvalidRegex(String),
}

pub fn check(assertion: &Assertion, output: &str) -> Result<bool, EvalError> {
    let trimmed = output.trim();
    match assertion.kind {
        AssertionKind::Exact => {
            let expected = assertion
                .value
                .as_deref()
                .ok_or(EvalError::MissingExpected)?;
            Ok(trimmed == expected)
        }
        AssertionKind::Contains => {
            let expected = assertion
                .value
                .as_deref()
                .ok_or(EvalError::MissingExpected)?;
            Ok(!expected.is_empty() && trimmed.to_lowercase().contains(&expected.to_lowercase()))
        }
        AssertionKind::Regex => {
            let expected = assertion
                .value
                .as_deref()
                .ok_or(EvalError::MissingExpected)?;
            let regex = Regex::new(expected).map_err(|e| EvalError::InvalidRegex(e.to_string()))?;
            Ok(regex.is_match(trimmed))
        }
        AssertionKind::JsonValid => Ok(matches!(
            serde_json::from_str::<serde_json::Value>(trimmed),
            Ok(serde_json::Value::Object(_))
        )),
    }
}

pub fn evaluate(
    suite: &EvalSuite,
    answers: &[(&str, &str)],
) -> Result<Vec<EvalVerdict>, EvalError> {
    suite
        .cases
        .iter()
        .map(|case| {
            let response = answers
                .iter()
                .find(|(id, _)| *id == case.id)
                .map_or("", |(_, value)| *value);
            Ok(EvalVerdict {
                case_id: case.id.clone(),
                passed: check(&case.assertion, response)?,
            })
        })
        .collect()
}

pub fn throughput(tokens: u64, duration_ms: f64) -> Option<f64> {
    if tokens == 0 || !duration_ms.is_finite() || duration_ms <= 0.0 {
        return None;
    }
    Some(tokens as f64 * 1000.0 / duration_ms)
}
