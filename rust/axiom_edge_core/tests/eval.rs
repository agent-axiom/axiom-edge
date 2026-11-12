use axiom_edge_core::{Assertion, AssertionKind, EvalSuite, check, evaluate, throughput};

#[test]
fn parses_shared_smoke_suite() {
    let suite: EvalSuite = serde_json::from_str(include_str!("../../../assets/evals/smoke.json"))
        .expect("shared suite must be valid JSON");
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
