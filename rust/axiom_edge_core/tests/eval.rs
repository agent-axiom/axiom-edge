use axiom_edge_core::{Assertion, AssertionKind, EvalSuite, check, evaluate, throughput};

#[test]
fn parses_shared_smoke_suite() {
    let suite: EvalSuite = serde_json::from_str(include_str!("../../../assets/evals/smoke.json"))
        .expect("shared suite must be valid JSON");
    assert_eq!(suite.suite, "pocket-smoke-v2");
    let json_case = suite
        .cases
        .iter()
        .find(|case| case.id == "structured-json")
        .unwrap();
    assert_eq!(json_case.assertion.kind, AssertionKind::JsonSuccessTrue);
    assert_eq!(suite.cases.len(), 3);
    let verdicts = evaluate(
        &suite,
        &[
            ("literal-answer", "4"),
            ("structured-json", "{\"success\":true}"),
            ("instruction-following", "A satellite orbits Earth."),
        ],
    )
    .unwrap();
    assert!(verdicts.iter().all(|v| v.passed));
}

#[test]
fn rejects_invalid_json_and_empty_contains() {
    let legacy: Assertion = serde_json::from_str(r#"{"kind":"json_valid"}"#).unwrap();
    assert!(check(&legacy, r#"{"success":false}"#).unwrap());
    assert!(
        !check(
            &Assertion {
                kind: AssertionKind::JsonValid,
                value: None
            },
            "[1]"
        )
        .unwrap()
    );
    assert!(
        !check(
            &Assertion {
                kind: AssertionKind::Contains,
                value: Some("".into())
            },
            "hello"
        )
        .unwrap()
    );
}

#[test]
fn structured_json_requires_a_top_level_boolean_success_set_to_true() {
    let assertion: Assertion = serde_json::from_str(r#"{"kind":"json_success_true"}"#).unwrap();
    assert!(check(&assertion, r#"{"success":true}"#).unwrap());
    assert!(check(&assertion, r#" { "extra": 0, "success": true } "#).unwrap());
    for response in [
        r#"{"success":false}"#,
        r#"{"success":"true"}"#,
        r#"{"success":1}"#,
        r#"{"success":null}"#,
        "{}",
        r#"{"nested":{"success":true}}"#,
        r#"[{"success":true}]"#,
        "true",
        r#"{"success":true"#,
        "```json\n{\"success\":true}\n```",
    ] {
        assert!(!check(&assertion, response).unwrap(), "{response}");
    }
}

#[test]
fn validates_regex() {
    let assertion = Assertion {
        kind: AssertionKind::Regex,
        value: Some("^[a-z]+$".into()),
    };
    assert!(check(&assertion, "hello").unwrap());
    assert!(!check(&assertion, "HELLO").unwrap());
}

#[test]
fn throughput_handles_missing_and_valid_measurements() {
    assert_eq!(throughput(256, 2000.0), Some(128.0));
    assert_eq!(throughput(0, 100.0), None);
    assert_eq!(throughput(20, 0.0), None);
    assert_eq!(throughput(20, f64::NAN), None);
}
